module main

@[noinline]
fn credits_per_batch(items int, batch_size int, credits int) int {
	completed_batches := items / batch_size
	return credits / completed_batches
}

fn main() {
	println('Calculating credits per completed batch.')
	println(credits_per_batch(3, 5, 120))
}
