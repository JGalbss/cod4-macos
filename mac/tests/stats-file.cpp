#include <posix/posix_stats_file.h>
#include <universal/com_stats_path.h>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <iostream>

int main()
{
    for (const char *valid : {"", "mods/new_experience", "Mods/stats_save_test", "mods/my-mod.2"})
        assert(stats_path::ValidDirectory(valid));
    for (const char *invalid : {"/tmp/stats", "../other", "mods/../other", "mods/./x", "mods//x", "mods/", "C:/stats", "mods\\x", "mods/x\ny"})
        assert(!stats_path::ValidDirectory(invalid));
    assert(!stats_path::ValidDirectory(std::string(260, 'a').c_str()));
    char root[] = "/tmp/kisak-stats-file.XXXXXX";
    assert(mkdtemp(root));
    const std::filesystem::path directory(root);
    const auto path = directory / "mpdata";
    const std::string first(8476, 'a'), second(8476, 'b');
    const auto read = [&]() {
        std::ifstream input(path, std::ios::binary);
        return std::string(std::istreambuf_iterator<char>(input), {});
    };
    assert(posix_stats::WriteAtomic(path.c_str(), first.data(), first.size()));
    assert(read() == first);
    assert(posix_stats::WriteAtomic(path.c_str(), second.data(), second.size()));
    assert(read() == second);
    assert(!posix_stats::WriteAtomic((directory / "missing/mpdata").c_str(), first.data(), first.size()));
    assert(read() == second);
    const auto blocked = directory / "blocked";
    std::filesystem::create_directory(blocked);
    assert(!posix_stats::WriteAtomic(blocked.c_str(), first.data(), first.size()));
    assert(std::filesystem::is_directory(blocked));
    assert(read() == second);
    for (const auto &entry : std::filesystem::directory_iterator(directory))
        assert(entry.path() == path || entry.path() == blocked);
    std::filesystem::remove(blocked);
    std::filesystem::remove(path);
    std::filesystem::remove(directory);
    std::cout << "ok: atomic stats creation/replacement, failed writes, and temporary-file cleanup\n";
}
