#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s /absolute/path/to/libSDL2-2.0.0.dylib\n", argv[0]);
        return 2;
    }

    void *library = dlopen(argv[1], RTLD_LOCAL | RTLD_NOW);
    if (!library)
    {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    if (!dlsym(library, "SDL_GetVersion"))
    {
        fprintf(stderr, "SDL_GetVersion lookup failed: %s\n", dlerror());
        dlclose(library);
        return 1;
    }

    dlclose(library);
    return 0;
}
