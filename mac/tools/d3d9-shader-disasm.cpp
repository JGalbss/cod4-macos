#include <d3dcompiler.h>

#include <cstdio>
#include <vector>

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        std::fprintf(stderr, "usage: %s shader.bin\n", argv[0]);
        return 2;
    }

    FILE *file = std::fopen(argv[1], "rb");
    if (!file)
        return 3;
    std::fseek(file, 0, SEEK_END);
    const long length = std::ftell(file);
    std::rewind(file);
    if (length <= 0)
    {
        std::fclose(file);
        return 4;
    }
    std::vector<unsigned char> data(static_cast<size_t>(length));
    const size_t read = std::fread(data.data(), 1, data.size(), file);
    std::fclose(file);
    if (read != data.size())
        return 5;

    ID3DBlob *assembly = nullptr;
    const HRESULT result = D3DDisassemble(data.data(), data.size(),
        D3D_DISASM_ENABLE_INSTRUCTION_NUMBERING | D3D_DISASM_ENABLE_DEFAULT_VALUE_PRINTS,
        nullptr, &assembly);
    if (FAILED(result) || !assembly)
    {
        std::fprintf(stderr, "D3DDisassemble failed: 0x%08lx\n",
                     static_cast<unsigned long>(result));
        return 6;
    }
    std::fwrite(assembly->GetBufferPointer(), 1, assembly->GetBufferSize(), stdout);
    assembly->Release();
    return 0;
}
