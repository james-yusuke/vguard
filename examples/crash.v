module main

fn C.abort()

fn crash_here() {
	// This example deliberately stops via SIGABRT.
	C.abort()
}

fn main() {
	println('About to call crash_here')
	crash_here()
}
