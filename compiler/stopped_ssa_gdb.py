import bisect
import json
import os

import gdb


def image_base(artifact):
    matches = []
    for line in gdb.execute('info proc mappings', to_string=True).splitlines():
        parts = line.split(None, 4)
        if len(parts) != 5 or not parts[0].startswith('0x') or int(parts[3], 16) != 0:
            continue
        path = parts[4].strip()
        if not path.startswith('/'):
            path = path.partition(' ')[2].lstrip()
        if path.startswith('/') and os.path.realpath(path) == artifact:
            matches.append(int(parts[0], 16))
    return min(matches) if matches else None


def register_bits(frame, register, frame_register):
    if frame_register == 'x29' and register.startswith(('d', 's')):
        return int(frame.read_register('v' + register[1:])['d']['u'][0])
    return int(frame.read_register(register))


def read_return_value(frame, home, frame_register):
    register = home['register']
    bits = register_bits(frame, register, frame_register) & ((1 << (home['bytes'] * 8)) - 1)
    if register == 's0':
        # The ARM64 return path widens then narrows. A zero could have come
        # from flushing a subnormal, and NaN payloads can change in conversion.
        magnitude = bits & 0x7fffffff
        if magnitude == 0 or magnitude > 0x7f800000:
            return ''
    return hex(bits)


def stack_bits(inferior, address, width):
    return int.from_bytes(bytes(inferior.read_memory(address, width)), 'little')


def read_homes(frame, inferior, homes, frame_register, prologue_offset):
    values = []
    try:
        fp = int(frame.read_register(frame_register))
        sp = int(frame.read_register('rsp' if frame_register == 'rbp' else 'sp'))
    except (gdb.error, ValueError):
        fp = 0
        sp = 0
    for home in homes:
        width = home['snapshot_bytes']
        try:
            entry = home.get('argument_entry', {})
            if prologue_offset is not None and not entry:
                continue
            if prologue_offset is not None and prologue_offset < entry['ready']:
                if entry.get('register') and (prologue_offset == 0 or entry.get('preserve_register')):
                    bits = register_bits(frame, entry['register'], frame_register)
                elif 'stack_offset' in entry and (prologue_offset == 0 or entry.get('frame_ready')):
                    stack = sp
                    if prologue_offset != 0 and prologue_offset >= entry['stack_adjusted']:
                        stack = fp if prologue_offset >= entry['frame_ready'] else sp
                        if stack:
                            stack += 8 if frame_register == 'rbp' else 16
                    if not stack:
                        continue
                    bits = stack_bits(inferior, stack + entry['stack_offset'], width)
                else:
                    continue
            elif 'object_offset' in home:
                if not fp:
                    continue
                alignment = home.get('object_alignment', 1)
                bits = (fp + home['object_offset'] + alignment - 1) & -alignment
                if not sp <= bits < fp:
                    continue
            elif home.get('register'):
                bits = register_bits(frame, home['register'], frame_register)
            elif fp and 'frame_offset' in home:
                address = fp + home['frame_offset']
                if address < sp or address + width > fp:
                    continue
                bits = stack_bits(inferior, address, width)
            else:
                continue
        except (gdb.error, ValueError, OverflowError, KeyError):
            continue
        values.append({'id': home['value'], 'bits': hex(bits & ((1 << (width * 8)) - 1))})
    return values


def collect(plan):
    selected = gdb.selected_thread()
    if selected is None:
        return []
    base = image_base(plan['artifact'])
    if base is None:
        return []
    inferior = gdb.selected_inferior()
    ranges = plan['ranges']
    starts = [region['start'] for region in ranges]
    frames = []
    threads = inferior.threads() if plan['all_frames'] else [selected]
    try:
        for thread in threads:
            thread.switch()
            frame = gdb.newest_frame()
            index = 0
            while frame is not None and index < 128 and len(frames) < 256:
                pc = frame.pc()
                address = pc - base + plan['preferred_base'] - (1 if index else 0)
                offset = bisect.bisect_right(starts, address) - 1
                if offset >= 0 and ranges[offset]['start'] <= address < ranges[offset]['end']:
                    region = ranges[offset]
                    prologue = region.get('prologue', False)
                    if not prologue or index == 0:
                        homes = plan['homes'].get(region['function'], [])
                        relative_pc = address - region['start']
                        return_home = region.get('return_home') if index == 0 else None
                        return_offset = region.get('recovery_prefix', 0)
                        return_bits = ''
                        if return_home and relative_pc >= return_offset:
                            try:
                                return_bits = read_return_value(frame, return_home, plan['frame_register'])
                            except (gdb.error, ValueError, OverflowError, KeyError):
                                pass
                            if relative_pc > return_offset:
                                homes = []
                        frames.append({
                            'thread': thread.num, 'selected': thread.num == selected.num,
                            'index': index, 'pc': hex(pc),
                            'at_entry': address == region['start'] and index == 0,
                            'return_bits': return_bits,
                            'values': read_homes(frame, inferior, homes, plan['frame_register'],
                                                 relative_pc if prologue else None),
                        })
                if not plan['all_frames']:
                    break
                frame = frame.older()
                index += 1
    finally:
        selected.switch()
    return frames


with open(vguard_recovery_plan, encoding='utf-8') as source:
    plan = json.load(source)
frames = collect(plan)
with open(vguard_recovery_output, 'w', encoding='utf-8') as destination:
    json.dump(frames, destination)
