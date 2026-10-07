mod cli;

use clap::Parser;

fn main() {
    if let Err(error) = cli::Cli::parse().run() {
        eprintln!("nixploy: {error:#}");
        std::process::exit(1);
    }
}
