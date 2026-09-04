#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

const char *OpcodeName(unsigned int opcode)
{
    static const char *const names[] = {
        "nop", "mov", "add", "sub", "mad", "mul", "rcp", "rsq", "dp3", "dp4",
        "min", "max", "slt", "sge", "exp", "log", "lit", "dst", "lrp", "frc",
        "m4x4", "m4x3", "m3x4", "m3x3", "m3x2", "call", "callnz", "loop", "ret",
        "endloop", "label", "dcl", "pow", "crs", "sgn", "abs", "nrm", "sincos",
        "rep", "endrep", "if", "ifc", "else", "endif", "break", "breakc", "mova",
        "defb", "defi",
    };
    if (opcode < sizeof(names) / sizeof(names[0]))
        return names[opcode];
    switch (opcode)
    {
    case 64: return "texcoord";
    case 65: return "texkill";
    case 66: return "texld";
    case 78: return "expp";
    case 79: return "logp";
    case 80: return "cnd";
    case 81: return "def";
    case 88: return "cmp";
    case 90: return "dp2add";
    case 91: return "dsx";
    case 92: return "dsy";
    case 93: return "texldd";
    case 94: return "setp";
    case 95: return "texldl";
    case 96: return "breakp";
    default: return "unknown";
    }
}

std::string RegisterName(uint32_t token)
{
    const unsigned int type = ((token >> 28) & 7u) | ((token >> 8) & 0x18u);
    const unsigned int index = token & 0x7ffu;
    const char *prefix = "?";
    switch (type)
    {
    case 0: prefix = "r"; break;
    case 1: prefix = "v"; break;
    case 2: prefix = "c"; break;
    case 3: prefix = "t"; break;
    case 6: prefix = "o"; break;
    case 7: prefix = "i"; break;
    case 8: prefix = "oC"; break;
    case 9: prefix = "oDepth"; break;
    case 10: prefix = "s"; break;
    case 11: prefix = "c"; break;
    case 12: prefix = "c"; break;
    case 13: prefix = "c"; break;
    case 14: prefix = "b"; break;
    case 15: prefix = "aL"; break;
    case 16: prefix = "h"; break;
    case 17: prefix = "vPos"; break;
    case 18: prefix = "l"; break;
    case 19: prefix = "p"; break;
    }
    const unsigned int adjustedIndex = type >= 11 && type <= 13
        ? index + (type - 10) * 2048 : index;
    if (type == 9 || type == 15 || type == 17)
        return prefix;
    return std::string(prefix) + std::to_string(adjustedIndex);
}

std::string Destination(uint32_t token)
{
    std::string result = RegisterName(token);
    const unsigned int mask = (token >> 16) & 0xfu;
    if (mask != 0xfu)
    {
        result += '.';
        static const char components[] = "xyzw";
        for (unsigned int i = 0; i < 4; ++i)
            if (mask & (1u << i))
                result += components[i];
    }
    if (((token >> 20) & 0xfu) == 1)
        result += "_sat";
    return result;
}

std::string Source(uint32_t token)
{
    std::string result = RegisterName(token);
    const unsigned int modifier = (token >> 24) & 0xfu;
    if (modifier == 1)
        result = "-" + result;
    else if (modifier == 11)
        result = "abs(" + result + ")";
    else if (modifier == 12)
        result = "-abs(" + result + ")";
    else if (modifier == 6)
        result = "1-" + result;

    const unsigned int swizzle = (token >> 16) & 0xffu;
    if (swizzle != 0xe4u)
    {
        result += '.';
        static const char components[] = "xyzw";
        for (unsigned int i = 0; i < 4; ++i)
            result += components[(swizzle >> (2 * i)) & 3u];
    }
    return result;
}

bool HasDestination(unsigned int opcode)
{
    switch (opcode)
    {
    case 0: case 25: case 26: case 27: case 28: case 29: case 30: case 38: case 39:
    case 40: case 41: case 42: case 43: case 44: case 45: case 60: case 96:
        return false;
    default:
        return true;
    }
}

float TokenFloat(uint32_t value)
{
    float result;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

} // namespace

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
    const long byteLength = std::ftell(file);
    std::rewind(file);
    if (byteLength < 4 || byteLength % 4)
        return 4;
    std::vector<uint32_t> tokens(static_cast<size_t>(byteLength) / 4);
    if (std::fread(tokens.data(), 4, tokens.size(), file) != tokens.size())
        return 5;
    std::fclose(file);

    const uint32_t version = tokens[0];
    std::printf("%s_%u_%u\n", (version >> 16) == 0xffffu ? "ps" : "vs",
                (version >> 8) & 0xffu, version & 0xffu);
    for (size_t cursor = 1; cursor < tokens.size();)
    {
        const uint32_t instruction = tokens[cursor];
        const unsigned int opcode = instruction & 0xffffu;
        if (opcode == 0xffffu)
        {
            std::puts("end");
            break;
        }
        if (opcode == 0xfffeu)
        {
            cursor += 1 + ((instruction >> 16) & 0x7fffu);
            continue;
        }
        const unsigned int parameterCount = (instruction >> 24) & 0xfu;
        if (!parameterCount || cursor + parameterCount >= tokens.size())
        {
            std::printf("unknown_token 0x%08x\n", instruction);
            ++cursor;
            continue;
        }
        std::printf("%s", OpcodeName(opcode));
        if (opcode == 31 && parameterCount >= 2)
        {
            const uint32_t usage = tokens[cursor + 1];
            std::printf("_%u_%u %s", usage & 0xfu, (usage >> 16) & 0xfu,
                        Destination(tokens[cursor + 2]).c_str());
        }
        else if (opcode == 81 && parameterCount >= 5)
        {
            std::printf(" %s, %.9g, %.9g, %.9g, %.9g",
                        Destination(tokens[cursor + 1]).c_str(),
                        TokenFloat(tokens[cursor + 2]), TokenFloat(tokens[cursor + 3]),
                        TokenFloat(tokens[cursor + 4]), TokenFloat(tokens[cursor + 5]));
        }
        else
        {
            for (unsigned int i = 0; i < parameterCount; ++i)
            {
                std::printf("%s%s", i ? ", " : " ",
                            i == 0 && HasDestination(opcode)
                                ? Destination(tokens[cursor + 1 + i]).c_str()
                                : Source(tokens[cursor + 1 + i]).c_str());
            }
        }
        std::putchar('\n');
        cursor += 1 + parameterCount;
    }
    return 0;
}
