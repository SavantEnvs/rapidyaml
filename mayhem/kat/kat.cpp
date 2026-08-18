// mayhem/kat/kat.cpp — known-answer probe for the mayhem/test.sh anti-sabotage
// oracle. Built with the project's NORMAL (non-sanitized) flags in build.sh,
// so it is a functional check, not a fuzz/triage artifact.
//
// Prints fixed `KAT_<NAME>=<value>` lines computed from a hardcoded YAML
// document by actually calling into ryml (parse, tree navigation, anchor
// resolution, and re-emission). mayhem/test.sh greps for the EXACT expected
// text with `grep -qxF`. Because every printed value only appears after a
// real, successful parse+lookup+resolve+emit sequence, a neutered binary
// (the verify-repo LD_PRELOAD sabotage shim `_exit(0)`s it before `main`
// runs) produces NO output at all, so every grep below fails and
// mayhem/test.sh fails — the required behavioral property (SPEC §6.3).
#include <ryml.hpp>
#include <ryml_std.hpp>
#include <cstdio>
#include <string>

static const char kYaml[] =
    "top: hello world\n"
    "seq: [10, 20, 30]\n"
    "nested:\n"
    "  a: &anchorval pinned-42\n"
    "  b: *anchorval\n"
    "  c: 7\n";

int main()
{
    // 1) parse
    ryml::Tree tree = ryml::parse_in_arena(ryml::to_csubstr(kYaml));

    // 2) direct scalar lookup
    ryml::ConstNodeRef top = tree["top"];
    if(!top.readable() || !top.has_val())
    {
        std::fprintf(stderr, "KAT FAIL: top is not a readable scalar\n");
        return 1;
    }
    std::printf("KAT_SCALAR=%.*s\n", (int)top.val().len, top.val().str);

    // 3) sequence length
    ryml::ConstNodeRef seq = tree["seq"];
    if(!seq.readable() || !seq.is_seq())
    {
        std::fprintf(stderr, "KAT FAIL: seq is not a readable sequence\n");
        return 1;
    }
    std::printf("KAT_SEQLEN=%zu\n", (size_t)seq.num_children());

    // 4) anchor/alias resolution — resolve() replaces the alias node's
    //    value with the anchor's value.
    tree.resolve();
    ryml::ConstNodeRef aliasval = tree["nested"]["b"];
    if(!aliasval.readable() || !aliasval.has_val())
    {
        std::fprintf(stderr, "KAT FAIL: nested.b did not resolve to a scalar\n");
        return 1;
    }
    std::printf("KAT_ALIAS=%.*s\n", (int)aliasval.val().len, aliasval.val().str);

    // 5) round-trip emission of the (now-resolved) tree, canonicalized to a
    //    single line by stripping newlines, so it is one grep-able KAT line.
    std::string emitted = ryml::emitrs_yaml<std::string>(tree);
    std::string canon;
    canon.reserve(emitted.size());
    for(char c : emitted)
        if(c != '\n')
            canon.push_back(c);
    std::printf("KAT_EMIT=%s\n", canon.c_str());

    return 0;
}
