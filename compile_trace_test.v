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
