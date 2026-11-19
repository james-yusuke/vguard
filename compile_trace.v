module main

import json2
import math
import os
import strconv

struct CompileStage {
	name        string
	duration_ms f64
	rss_mb      int
}

struct CompileTrace {
	version    int = 1
	source     string
	compiler   string
	backend    string
	target     string
	artifact   string
	status     string
	exit_code  int
	elapsed_ms i64
	stages     []CompileStage
}

fn compile_stages(stdout string) []CompileStage {
	mut stages := []CompileStage{}
	for line in stdout.split_into_lines() {
		if !line.starts_with('  ') || line.starts_with('   ') {
			continue
		}
		rss := line.index(' MB RSS') or { continue }
		fields := line[..rss].fields()
		if fields.len < 4 || fields[fields.len - 2] != 'ms' {
			continue
		}
		duration := strconv.atof64(fields[fields.len - 3]) or { continue }
		memory := strconv.atoi(fields.last()) or { continue }
		if duration < 0 || math.is_nan(duration) || math.is_inf(duration, 0) || memory < 0 {
			continue
		}
		stages << CompileStage{
			name:        fields[..fields.len - 3].join(' ')
			duration_ms: duration
			rss_mb:      memory
		}
	}
	return stages
}

fn mermaid_label(label string) string {
	return label.replace_each(['"', '#quot;', '#', '#35;', '<', '#60;', '>', '#62;', '&', '#38;',
		'\r', ' ', '\n', ' '])
}

fn (trace CompileTrace) mermaid() string {
	mut labels := ['Native compilation (${trace.backend}, ${trace.target})']
	for stage in trace.stages {
		// The arm64 driver labels object and map output as "link" in its timings.
		name := if trace.backend == 'arm64' && os.file_ext(trace.artifact) == '.o'
			&& stage.name == 'link' {
			'object and SSA map output'
		} else {
			stage.name
		}
		labels << '${name} (${stage.duration_ms:.2f} ms)'
	}
	if trace.stages.len == 0 {
		labels << 'No compiler stage timings recorded'
	}
	labels << if trace.status == 'exited' && trace.exit_code == 0 {
		'Compiler exited successfully (${trace.elapsed_ms} ms elapsed)'
	} else {
		'Compiler failed (${trace.status}, code ${trace.exit_code}, ${trace.elapsed_ms} ms elapsed)'
	}
	mut lines := ['flowchart TD']
	for i, label in labels {
		lines << '    n${i}["${mermaid_label(label)}"]'
		if i > 0 {
			lines << '    n${i - 1} --> n${i}'
		}
	}
	return lines.join('\n') + '\n'
}

fn save_compile_trace(options BuildOptions, out string, result Outcome, elapsed_ms i64) ! {
	trace := CompileTrace{
		source:     options.source
		compiler:   options.compiler
		backend:    options.backend
		target:     options.target
		artifact:   artifact_name(options)
		status:     result.status
		exit_code:  result.exit_code
		elapsed_ms: elapsed_ms
		stages:     compile_stages(result.stdout)
	}
	trace_path := os.join_path(out, 'compile-trace.json')
	flow_path := os.join_path(out, 'compile-flow.mmd')
	os.write_file(os.join_path(out, 'compiler.stdout.log'), result.stdout)!
	os.write_file(os.join_path(out, 'compiler.stderr.log'), result.stderr)!
	os.write_file(trace_path, json2.encode(trace, prettify: true) + '\n')!
	os.write_file(flow_path, trace.mermaid())!
	if trace.stages.len == 0 {
		eprintln('VGuard: no compiler stage timings were recorded')
	}
	eprintln('VGuard: compile trace saved to ${trace_path}')
	eprintln('VGuard: Mermaid flow saved to ${flow_path}')
}
