module main

fn C.abort()

@[noinline]
fn check_batch(expected int, accepted int) {
	if accepted != expected {
		eprintln('The batch contains fewer accepted rows than expected.')
		C.abort()
	}
}

fn main() {
	rows := ['ready', '']
	mut accepted := 0
	defer {
		check_batch(rows.len, accepted)
	}
	for row in rows {
		if row != '' {
			accepted++
		}
	}
	println('Finished reading the batch.')
}
