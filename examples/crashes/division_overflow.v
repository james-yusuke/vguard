module main

@[noinline]
fn account_units(balance i64, units_per_credit i64) i64 {
	return balance / units_per_credit
}

fn main() {
	minimum_balance := i64(-9223372036854775807) - 1
	println('Converting a signed balance to the reverse accounting unit.')
	println(account_units(minimum_balance, -1))
}
