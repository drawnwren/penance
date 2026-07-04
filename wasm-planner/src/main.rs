use std::io::{self, Read};

fn main() {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .expect("failed to read planner input from stdin");

    print!("{}", penance_wasm_planner::normalize_project(&input));
}
