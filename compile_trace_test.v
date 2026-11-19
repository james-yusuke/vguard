module main

fn test_compile_stages_read_benchmark_rows_in_order() {
	stages := compile_stages('=== V compiler benchmark ===\r\n' +
		'  parse .v (parallel) 23.39 ms 49 MB RSS 43 MB physical footprint\r\n' +
		'    ignored detail 4.00 ms 70 MB RSS\r\n' +
		'  check NaN ms 71 MB RSS\r\n' +
		'  check 61.83 ms 71 MB RSS 71 MB stage peak\r\n' +
		'  ssa build 28.03 ms 136 MB RSS 121 MB physical footprint\r\n' +
		'  total 100.00 ms\r\n')
	assert stages.map(it.name) == ['parse .v (parallel)', 'check', 'ssa build']
	assert stages.map(it.rss_mb) == [49, 71, 136]
	assert stages[0].duration_ms == 23.39
}

fn test_compile_mermaid_escapes_labels_and_preserves_order() {
	trace := CompileTrace{
		backend:    'arm64'
		target:     'macos/arm64'
		status:     'exited'
		elapsed_ms: 100
		stages:     [CompileStage{ name: 'ssa "<build>#&"', duration_ms: 23.39 },
			CompileStage{ name: 'arm64 gen', duration_ms: 4 }]
	}
	assert trace.mermaid() == 'flowchart TD
    n0["Native compilation (arm64, macos/arm64)"]
    n1["ssa #quot;#60;build#62;#35;#38;#quot; (23.39 ms)"]
    n0 --> n1
    n2["arm64 gen (4.00 ms)"]
    n1 --> n2
    n3["Compiler exited successfully (100 ms elapsed)"]
    n2 --> n3
'
}

fn test_compile_mermaid_reports_failure_without_timings() {
	trace := CompileTrace{
		backend:   'amd64'
		target:    'linux/amd64'
		status:    'start_error'
		exit_code: -1
	}
	flow := trace.mermaid()
	assert flow.contains('No compiler stage timings recorded')
	assert flow.contains('Compiler failed (start_error, code -1, 0 ms elapsed)')
	assert !flow.contains('ssa build')
}

fn test_compile_mermaid_describes_arm64_object_output() {
	trace := CompileTrace{
		backend:  'arm64'
		artifact: 'program.o'
		stages:   [CompileStage{ name: 'link', duration_ms: 4 }]
	}
	assert trace.mermaid().contains('object and SSA map output (4.00 ms)')
	assert trace.stages[0].name == 'link'
}
