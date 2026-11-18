module main

import os

fn main() {
	if os.args.len != 2 {
		eprintln('Pass a label as the first argument.')
		exit(2)
	}
	message := os.get_line()
	println('${os.args[1]}: ${message}')
}
