// ChromaGlow patch (vendored from crates.io dns-sd 0.1.3, MIT): upstream only
// recognised "darwin" targets as Apple and fell back to Avahi via pkg-config
// on iOS. Every Apple target ships dns_sd in libSystem, so skip pkg-config for
// all of them. This is the only change.
extern crate pkg_config;

fn get_target() -> String {
    std::env::var("TARGET").unwrap()
}
fn main() {
    if !get_target().contains("apple") {
        pkg_config::find_library("avahi-compat-libdns_sd").unwrap();
    }
}
