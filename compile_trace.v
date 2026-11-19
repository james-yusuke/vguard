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
	os.write_file(os.join_path(out, 'compiler.stdout.log'), result.stdout)!
	os.write_file(os.join_path(out, 'compiler.stderr.log'), result.stderr)!
	os.write_file(trace_path, json2.encode(trace, prettify: true) + '\n')!
	if trace.stages.len == 0 {
		eprintln('VGuard: no compiler stage timings were recorded')
	}
	eprintln('VGuard: compile trace saved to ${trace_path}')
}
