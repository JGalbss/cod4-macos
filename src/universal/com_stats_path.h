#pragma once
#include <cstring>

namespace stats_path
{
inline bool ValidDirectory(const char *path)
{
    if (!path || !*path)
        return true;
    if (std::strlen(path) >= 260)
        return false;
    const char *component = path;
    for (const char *p = path; ; ++p)
    {
        if (*p == '\\' || *p == ':' || (static_cast<unsigned char>(*p) < 32 && *p))
            return false;
        if (*p == '/' || !*p)
        {
            const auto length = p - component;
            if (!length || (length == 1 && *component == '.') ||
                (length == 2 && component[0] == '.' && component[1] == '.'))
                return false;
            if (!*p)
                return true;
            component = p + 1;
        }
    }
}
}
