import gdb


def write_runtime_stop(frame_register):
    thread = gdb.selected_thread()
    if thread is None:
        return
    process, lwp, _ = thread.ptid
    if process <= 0 or lwp <= 0:
        return
    print(f'VGUARD_RUNTIME_THREAD {process} {lwp} {thread.num}')

    frame = gdb.newest_frame()
    for index in range(128):
        if frame is None:
            break
        try:
            pc = frame.pc()
            if frame.type() in (gdb.NORMAL_FRAME, gdb.SENTINEL_FRAME):
                pointer = int(frame.read_register(frame_register))
                if pointer > 0:
                    print(f'VGUARD_RUNTIME_FRAME {index} {pc:#x} {pointer:#x}')
        except (gdb.error, ValueError, OverflowError):
            pass
        frame = frame.older()


write_runtime_stop(vguard_frame_register)
