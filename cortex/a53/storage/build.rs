//! Re-embeds the migrations when one is added or edited.
//!
//! `sqlx::migrate!` reads the directory at compile time, but Cargo only
//! rebuilds the crate for files it knows about; a brand-new migration file
//! would otherwise be missing from the binary until something else changed.

fn main() {
    println!("cargo:rerun-if-changed=migrations");
}
