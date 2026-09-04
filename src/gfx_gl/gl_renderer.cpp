// Implementacao do renderer GLES2 minimal — ver gl_renderer.h.

#include "gl_renderer.h"

#include <cstdio>
#include <vector>

#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>

// GL header conditional: GLES2 no Switch/Android, Apple OpenGL framework
// no macOS (legacy 2.1 Compat suficiente pras funcoes que usamos), Linux
// usa o header generic. Todas as funcoes que tocamos
// (glCreateShader/.../glDrawArrays) sao GL 2.0+ core OU GLES 2.0.
#if defined(__SWITCH__)
    #include <GLES2/gl2.h>
#elif defined(__APPLE__)
    #define GL_SILENCE_DEPRECATION
    #include <OpenGL/gl.h>
#else
    #include <GL/gl.h>
#endif

namespace gfx_gl {

namespace {

// Compativel com GLSL ES 1.00 (Switch via mesa-nouveau) e GLSL 1.20
// (macOS OpenGL 2.1 Compat). O qualificador `precision` so existe em
// GLSL ES — o `#ifdef GL_ES` e parseado pelo compilador GLSL.
constexpr const char *VERTEX_SRC =
    "attribute vec3 a_pos;\n"
    "attribute vec3 a_col;\n"
    "uniform mat4 u_mvp;\n"
    "varying vec3 v_col;\n"
    "void main() {\n"
    "    v_col = a_col;\n"
    "    gl_Position = u_mvp * vec4(a_pos, 1.0);\n"
    "}\n";

constexpr const char *FRAGMENT_SRC =
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "varying vec3 v_col;\n"
    "void main() {\n"
    "    gl_FragColor = vec4(v_col, 1.0);\n"
    "}\n";

// Cubo unitario centrado na origem. Cada vertice tem cor distinta — vai
// dar gradiente nas faces.
constexpr GLfloat CUBE_VERTS[] = {
//   x      y      z      r     g     b
    -0.5f, -0.5f, -0.5f,  0.0f, 0.0f, 0.0f, // 0: traseira-inferior-esq, preto
     0.5f, -0.5f, -0.5f,  1.0f, 0.0f, 0.0f, // 1: traseira-inferior-dir, vermelho
     0.5f,  0.5f, -0.5f,  1.0f, 1.0f, 0.0f, // 2: traseira-superior-dir, amarelo
    -0.5f,  0.5f, -0.5f,  0.0f, 1.0f, 0.0f, // 3: traseira-superior-esq, verde
    -0.5f, -0.5f,  0.5f,  0.0f, 0.0f, 1.0f, // 4: frontal-inferior-esq, azul
     0.5f, -0.5f,  0.5f,  1.0f, 0.0f, 1.0f, // 5: frontal-inferior-dir, magenta
     0.5f,  0.5f,  0.5f,  1.0f, 1.0f, 1.0f, // 6: frontal-superior-dir, branco
    -0.5f,  0.5f,  0.5f,  0.0f, 1.0f, 1.0f, // 7: frontal-superior-esq, ciano
};

constexpr GLushort CUBE_INDICES[] = {
    // 12 triangulos (2 por face, 6 faces). Ordem CCW olhando de fora.
    4, 5, 6,  4, 6, 7, // frontal
    1, 0, 3,  1, 3, 2, // traseira
    0, 4, 7,  0, 7, 3, // esquerda
    5, 1, 2,  5, 2, 6, // direita
    3, 7, 6,  3, 6, 2, // topo
    0, 1, 5,  0, 5, 4, // base
};

GLuint g_program       = 0;
GLint  g_u_mvp         = -1;
int    g_viewport_w    = 1280;
int    g_viewport_h    = 720;

// Flat-color program para 2D UI (RC_STRETCH_PIC). Separado do cubo demo
// pra nao misturar atributos.
constexpr const char *FLAT_VERTEX_SRC =
    "attribute vec2 a_pos;\n"
    "void main() {\n"
    "    gl_Position = vec4(a_pos, 0.0, 1.0);\n"
    "}\n";

constexpr const char *FLAT_FRAGMENT_SRC =
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "uniform vec4 u_color;\n"
    "void main() {\n"
    "    gl_FragColor = u_color;\n"
    "}\n";

GLuint g_flat_program = 0;
GLint  g_flat_u_color = -1;

// Programa textured pra UI (texto via atlas 8x8).
constexpr const char *TEX_VERTEX_SRC =
    "attribute vec2 a_pos;\n"
    "attribute vec2 a_uv;\n"
    "varying vec2 v_uv;\n"
    "void main() {\n"
    "    v_uv = a_uv;\n"
    "    gl_Position = vec4(a_pos, 0.0, 1.0);\n"
    "}\n";

constexpr const char *TEX_FRAGMENT_SRC =
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "uniform sampler2D u_tex;\n"
    "uniform vec4 u_color;\n"
    "varying vec2 v_uv;\n"
    "void main() {\n"
    "    float a = texture2D(u_tex, v_uv).r;\n"
    "    gl_FragColor = vec4(u_color.rgb, u_color.a * a);\n"
    "}\n";

GLuint g_tex_program = 0;
GLint  g_tex_u_color = -1;
GLint  g_tex_u_tex   = -1;
GLuint g_font_tex    = 0;

// Programa pra imagens RGBA da UI (RC_STRETCH_PIC com material texturizado).
// Separado do de texto: aquele le .r como mascara de alpha da font, o que
// pintaria qualquer textura de cor solida.
constexpr const char *IMG_FRAGMENT_SRC =
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "uniform sampler2D u_tex;\n"
    "uniform vec4 u_color;\n"
    "varying vec2 v_uv;\n"
    "void main() {\n"
    "    gl_FragColor = texture2D(u_tex, v_uv) * u_color;\n"
    "}\n";

GLuint g_img_program = 0;
GLint  g_img_u_color = -1;
GLint  g_img_u_tex   = -1;

// Font 8x8 minima ASCII printable (32..126). Cada char e 8 bytes (1 por
// linha), bit 7 = pixel mais a esquerda. Subset compacto, suficiente pra
// menus CoD4 (uppercase + dig + pontuacao basica). Lowercase reusa o
// glyph uppercase pra simplicidade.
constexpr uint8_t kFont8x8[96][8] = {
    // 32 ' '
    {0,0,0,0,0,0,0,0},
    // 33 '!'
    {0x18,0x18,0x18,0x18,0x18,0x00,0x18,0x00},
    // 34 '"'
    {0x66,0x66,0x66,0x00,0x00,0x00,0x00,0x00},
    // 35 '#'
    {0x66,0x66,0xFF,0x66,0xFF,0x66,0x66,0x00},
    // 36 '$'
    {0x18,0x3E,0x60,0x3C,0x06,0x7C,0x18,0x00},
    // 37 '%'
    {0x62,0x66,0x0C,0x18,0x30,0x66,0x46,0x00},
    // 38 '&'
    {0x3C,0x66,0x3C,0x38,0x67,0x66,0x3F,0x00},
    // 39 '''
    {0x18,0x18,0x30,0x00,0x00,0x00,0x00,0x00},
    // 40 '('
    {0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00},
    // 41 ')'
    {0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00},
    // 42 '*'
    {0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00},
    // 43 '+'
    {0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00},
    // 44 ','
    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30},
    // 45 '-'
    {0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00},
    // 46 '.'
    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00},
    // 47 '/'
    {0x00,0x03,0x06,0x0C,0x18,0x30,0x60,0x00},
    // 48 '0'
    {0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0x00},
    // 49 '1'
    {0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00},
    // 50 '2'
    {0x3C,0x66,0x06,0x0C,0x30,0x60,0x7E,0x00},
    // 51 '3'
    {0x3C,0x66,0x06,0x1C,0x06,0x66,0x3C,0x00},
    // 52 '4'
    {0x06,0x0E,0x1E,0x66,0x7F,0x06,0x06,0x00},
    // 53 '5'
    {0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0x00},
    // 54 '6'
    {0x3C,0x66,0x60,0x7C,0x66,0x66,0x3C,0x00},
    // 55 '7'
    {0x7E,0x66,0x0C,0x18,0x18,0x18,0x18,0x00},
    // 56 '8'
    {0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0x00},
    // 57 '9'
    {0x3C,0x66,0x66,0x3E,0x06,0x66,0x3C,0x00},
    // 58 ':'
    {0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00},
    // 59 ';'
    {0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x30},
    // 60 '<'
    {0x0E,0x18,0x30,0x60,0x30,0x18,0x0E,0x00},
    // 61 '='
    {0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00},
    // 62 '>'
    {0x70,0x18,0x0C,0x06,0x0C,0x18,0x70,0x00},
    // 63 '?'
    {0x3C,0x66,0x06,0x0C,0x18,0x00,0x18,0x00},
    // 64 '@'
    {0x3C,0x66,0x6E,0x6E,0x60,0x62,0x3C,0x00},
    // 65 'A'
    {0x18,0x3C,0x66,0x7E,0x66,0x66,0x66,0x00},
    // 66 'B'
    {0x7C,0x66,0x66,0x7C,0x66,0x66,0x7C,0x00},
    // 67 'C'
    {0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0x00},
    // 68 'D'
    {0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0x00},
    // 69 'E'
    {0x7E,0x60,0x60,0x78,0x60,0x60,0x7E,0x00},
    // 70 'F'
    {0x7E,0x60,0x60,0x78,0x60,0x60,0x60,0x00},
    // 71 'G'
    {0x3C,0x66,0x60,0x6E,0x66,0x66,0x3C,0x00},
    // 72 'H'
    {0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00},
    // 73 'I'
    {0x7E,0x18,0x18,0x18,0x18,0x18,0x7E,0x00},
    // 74 'J'
    {0x06,0x06,0x06,0x06,0x06,0x66,0x3C,0x00},
    // 75 'K'
    {0x66,0x6C,0x78,0x70,0x78,0x6C,0x66,0x00},
    // 76 'L'
    {0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00},
    // 77 'M'
    {0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0x00},
    // 78 'N'
    {0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0x00},
    // 79 'O'
    {0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0x00},
    // 80 'P'
    {0x7C,0x66,0x66,0x7C,0x60,0x60,0x60,0x00},
    // 81 'Q'
    {0x3C,0x66,0x66,0x66,0x66,0x3C,0x0E,0x00},
    // 82 'R'
    {0x7C,0x66,0x66,0x7C,0x78,0x6C,0x66,0x00},
    // 83 'S'
    {0x3C,0x66,0x60,0x3C,0x06,0x66,0x3C,0x00},
    // 84 'T'
    {0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x00},
    // 85 'U'
    {0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00},
    // 86 'V'
    {0x66,0x66,0x66,0x66,0x66,0x3C,0x18,0x00},
    // 87 'W'
    {0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00},
    // 88 'X'
    {0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x00},
    // 89 'Y'
    {0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x00},
    // 90 'Z'
    {0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E,0x00},
    // 91 '['
    {0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00},
    // 92 '\'
    {0x00,0x60,0x30,0x18,0x0C,0x06,0x03,0x00},
    // 93 ']'
    {0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00},
    // 94 '^'
    {0x18,0x3C,0x66,0x00,0x00,0x00,0x00,0x00},
    // 95 '_'
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF},
    // 96 '`'
    {0x30,0x18,0x0C,0x00,0x00,0x00,0x00,0x00},
    // 97 'a' (= A)
    {0x00,0x00,0x3C,0x06,0x3E,0x66,0x3E,0x00},
    // 98 'b'
    {0x60,0x60,0x7C,0x66,0x66,0x66,0x7C,0x00},
    // 99 'c'
    {0x00,0x00,0x3C,0x66,0x60,0x66,0x3C,0x00},
    // 100 'd'
    {0x06,0x06,0x3E,0x66,0x66,0x66,0x3E,0x00},
    // 101 'e'
    {0x00,0x00,0x3C,0x66,0x7E,0x60,0x3C,0x00},
    // 102 'f'
    {0x0E,0x18,0x3E,0x18,0x18,0x18,0x18,0x00},
    // 103 'g'
    {0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x7C},
    // 104 'h'
    {0x60,0x60,0x7C,0x66,0x66,0x66,0x66,0x00},
    // 105 'i'
    {0x18,0x00,0x38,0x18,0x18,0x18,0x3C,0x00},
    // 106 'j'
    {0x06,0x00,0x06,0x06,0x06,0x06,0x66,0x3C},
    // 107 'k'
    {0x60,0x60,0x66,0x6C,0x78,0x6C,0x66,0x00},
    // 108 'l'
    {0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00},
    // 109 'm'
    {0x00,0x00,0x66,0x7F,0x7F,0x6B,0x63,0x00},
    // 110 'n'
    {0x00,0x00,0x7C,0x66,0x66,0x66,0x66,0x00},
    // 111 'o'
    {0x00,0x00,0x3C,0x66,0x66,0x66,0x3C,0x00},
    // 112 'p'
    {0x00,0x00,0x7C,0x66,0x66,0x7C,0x60,0x60},
    // 113 'q'
    {0x00,0x00,0x3E,0x66,0x66,0x3E,0x06,0x06},
    // 114 'r'
    {0x00,0x00,0x7C,0x66,0x60,0x60,0x60,0x00},
    // 115 's'
    {0x00,0x00,0x3E,0x60,0x3C,0x06,0x7C,0x00},
    // 116 't'
    {0x18,0x18,0x3E,0x18,0x18,0x18,0x0E,0x00},
    // 117 'u'
    {0x00,0x00,0x66,0x66,0x66,0x66,0x3E,0x00},
    // 118 'v'
    {0x00,0x00,0x66,0x66,0x66,0x3C,0x18,0x00},
    // 119 'w'
    {0x00,0x00,0x63,0x6B,0x7F,0x7F,0x36,0x00},
    // 120 'x'
    {0x00,0x00,0x66,0x3C,0x18,0x3C,0x66,0x00},
    // 121 'y'
    {0x00,0x00,0x66,0x66,0x66,0x3E,0x06,0x7C},
    // 122 'z'
    {0x00,0x00,0x7E,0x0C,0x18,0x30,0x7E,0x00},
    // 123 '{'
    {0x1C,0x30,0x30,0x60,0x30,0x30,0x1C,0x00},
    // 124 '|'
    {0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x00},
    // 125 '}'
    {0x38,0x0C,0x0C,0x06,0x0C,0x0C,0x38,0x00},
    // 126 '~'
    {0x00,0x00,0x76,0xDC,0x00,0x00,0x00,0x00},
    // 127
    {0,0,0,0,0,0,0,0},
};

GLuint compile_shader(GLenum type, const char *src)
{
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, nullptr);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512] = {};
        glGetShaderInfoLog(sh, sizeof(log), nullptr, log);
        std::fprintf(stderr, "[gfx_gl] shader compile error: %s\n", log);
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

GLuint link_program(GLuint vs, GLuint fs)
{
    GLuint p = glCreateProgram();
    glAttachShader(p, vs);
    glAttachShader(p, fs);
    glBindAttribLocation(p, 0, "a_pos");
    glBindAttribLocation(p, 1, "a_col");
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512] = {};
        glGetProgramInfoLog(p, sizeof(log), nullptr, log);
        std::fprintf(stderr, "[gfx_gl] program link error: %s\n", log);
        glDeleteProgram(p);
        return 0;
    }
    return p;
}

} // namespace

bool init()
{
    GLuint vs = compile_shader(GL_VERTEX_SHADER, VERTEX_SRC);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, FRAGMENT_SRC);
    if (!vs || !fs) {
        return false;
    }
    g_program = link_program(vs, fs);
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (!g_program) {
        return false;
    }
    g_u_mvp = glGetUniformLocation(g_program, "u_mvp");

    // Programa flat 2D pra UI.
    GLuint fvs = compile_shader(GL_VERTEX_SHADER, FLAT_VERTEX_SRC);
    GLuint ffs = compile_shader(GL_FRAGMENT_SHADER, FLAT_FRAGMENT_SRC);
    if (!fvs || !ffs) return false;
    g_flat_program = glCreateProgram();
    glAttachShader(g_flat_program, fvs);
    glAttachShader(g_flat_program, ffs);
    glBindAttribLocation(g_flat_program, 0, "a_pos");
    glLinkProgram(g_flat_program);
    glDeleteShader(fvs);
    glDeleteShader(ffs);
    GLint ok = 0;
    glGetProgramiv(g_flat_program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512] = {};
        glGetProgramInfoLog(g_flat_program, sizeof(log), nullptr, log);
        std::fprintf(stderr, "[gfx_gl] flat link error: %s\n", log);
        return false;
    }
    g_flat_u_color = glGetUniformLocation(g_flat_program, "u_color");

    // Programa textured 2D pra texto.
    GLuint tvs = compile_shader(GL_VERTEX_SHADER, TEX_VERTEX_SRC);
    GLuint tfs = compile_shader(GL_FRAGMENT_SHADER, TEX_FRAGMENT_SRC);
    if (!tvs || !tfs) return false;
    g_tex_program = glCreateProgram();
    glAttachShader(g_tex_program, tvs);
    glAttachShader(g_tex_program, tfs);
    glBindAttribLocation(g_tex_program, 0, "a_pos");
    glBindAttribLocation(g_tex_program, 1, "a_uv");
    glLinkProgram(g_tex_program);
    glDeleteShader(tvs);
    glDeleteShader(tfs);
    glGetProgramiv(g_tex_program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512] = {};
        glGetProgramInfoLog(g_tex_program, sizeof(log), nullptr, log);
        std::fprintf(stderr, "[gfx_gl] tex link error: %s\n", log);
        return false;
    }
    g_tex_u_color = glGetUniformLocation(g_tex_program, "u_color");
    g_tex_u_tex   = glGetUniformLocation(g_tex_program, "u_tex");

    // Mesmo vertex shader do texto; so o fragment muda.
    GLuint ivs = compile_shader(GL_VERTEX_SHADER, TEX_VERTEX_SRC);
    GLuint ifs = compile_shader(GL_FRAGMENT_SHADER, IMG_FRAGMENT_SRC);
    if (!ivs || !ifs) return false;
    g_img_program = glCreateProgram();
    glAttachShader(g_img_program, ivs);
    glAttachShader(g_img_program, ifs);
    glBindAttribLocation(g_img_program, 0, "a_pos");
    glBindAttribLocation(g_img_program, 1, "a_uv");
    glLinkProgram(g_img_program);
    glDeleteShader(ivs);
    glDeleteShader(ifs);
    glGetProgramiv(g_img_program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512] = {};
        glGetProgramInfoLog(g_img_program, sizeof(log), nullptr, log);
        std::fprintf(stderr, "[gfx_gl] img link error: %s\n", log);
        return false;
    }
    g_img_u_color = glGetUniformLocation(g_img_program, "u_color");
    g_img_u_tex   = glGetUniformLocation(g_img_program, "u_tex");

    // Atlas da font: 16 chars de largura, 8 de altura → 128x64 pixels.
    // Char N esta na celula (N % 16) * 8, (N / 16) * 8.
    constexpr int kAtlasW = 128;
    constexpr int kAtlasH = 64;
    uint8_t atlas[kAtlasW * kAtlasH] = {0};
    for (int c = 0; c < 96; ++c) {
        const int cellX = (c % 16) * 8;
        const int cellY = (c / 16) * 8;
        for (int row = 0; row < 8; ++row) {
            const uint8_t bits = kFont8x8[c][row];
            for (int col = 0; col < 8; ++col) {
                const int px = cellX + col;
                const int py = cellY + row;
                atlas[py * kAtlasW + px] = (bits & (1u << (7 - col))) ? 0xFF : 0x00;
            }
        }
    }
    glGenTextures(1, &g_font_tex);
    glBindTexture(GL_TEXTURE_2D, g_font_tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, kAtlasW, kAtlasH, 0,
                 GL_LUMINANCE, GL_UNSIGNED_BYTE, atlas);
    glBindTexture(GL_TEXTURE_2D, 0);

    glClearColor(0.10f, 0.12f, 0.15f, 1.0f);
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LESS);
    glEnable(GL_CULL_FACE);
    glCullFace(GL_BACK);
    glFrontFace(GL_CCW);
    return true;
}

void set_viewport(int width, int height)
{
    g_viewport_w = width;
    g_viewport_h = height;
    glViewport(0, 0, width, height);
}

void apply_clear_color(float r, float g, float b, float a)
{
    glClearColor(r, g, b, a);
}

void clear_now(float r, float g, float b, float a)
{
    glClearColor(r, g, b, a);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
}

void draw_ui_text(float x, float y, const char *text,
                  float charW, float charH,
                  float r, float g, float b, float a)
{
    if (!text || !*text) return;
    const float displayW = float(g_viewport_w);
    const float displayH = float(g_viewport_h);
    auto to_ndc_x = [&](float vx) { return (vx / displayW) * 2.0f - 1.0f; };
    auto to_ndc_y = [&](float vy) { return 1.0f - (vy / displayH) * 2.0f; };

    // Cada char gera 2 triangulos = 6 vertices. Cada vertex: pos.xy + uv.xy = 4 floats.
    // Limite arbitrario de chars por chamada (suficiente pra qualquer label).
    constexpr int kMaxChars = 256;
    int len = 0;
    while (text[len] && len < kMaxChars) ++len;

    static float verts[kMaxChars * 6 * 4];
    int vCount = 0;
    for (int i = 0; i < len; ++i) {
        unsigned char ch = static_cast<unsigned char>(text[i]);
        if (ch < 32 || ch > 127) ch = '?';
        const int idx = ch - 32;
        const float cellX = (idx % 16) * 8.0f;
        const float cellY = (idx / 16) * 8.0f;
        const float u0 = cellX / 128.0f;
        const float v0 = cellY / 64.0f;
        const float u1 = (cellX + 8.0f) / 128.0f;
        const float v1 = (cellY + 8.0f) / 64.0f;
        const float qx0 = x + i * charW;
        const float qy0 = y;
        const float qx1 = qx0 + charW;
        const float qy1 = qy0 + charH;
        const float xn0 = to_ndc_x(qx0);
        const float xn1 = to_ndc_x(qx1);
        const float yn0 = to_ndc_y(qy0);
        const float yn1 = to_ndc_y(qy1);
        // tri 1
        verts[vCount++] = xn0; verts[vCount++] = yn0; verts[vCount++] = u0; verts[vCount++] = v0;
        verts[vCount++] = xn1; verts[vCount++] = yn0; verts[vCount++] = u1; verts[vCount++] = v0;
        verts[vCount++] = xn0; verts[vCount++] = yn1; verts[vCount++] = u0; verts[vCount++] = v1;
        // tri 2
        verts[vCount++] = xn1; verts[vCount++] = yn0; verts[vCount++] = u1; verts[vCount++] = v0;
        verts[vCount++] = xn1; verts[vCount++] = yn1; verts[vCount++] = u1; verts[vCount++] = v1;
        verts[vCount++] = xn0; verts[vCount++] = yn1; verts[vCount++] = u0; verts[vCount++] = v1;
    }

    glUseProgram(g_tex_program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, g_font_tex);
    glUniform1i(g_tex_u_tex, 0);
    glUniform4f(g_tex_u_color, r, g, b, a);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), verts);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), verts + 2);
    glDrawArrays(GL_TRIANGLES, 0, vCount / 4);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(0);
}

// UI quads were one glDrawArrays each, from client-side memory. On macOS's GL 2.1
// driver that copies and flushes per call, and a menu is hundreds of quads - every
// glyph is one - which put frame times at 22-44 ms for a 2D screen.
//
// Quads now accumulate into a single dynamic buffer and flush when the state that
// cannot be expressed per-vertex changes: program, texture, or colour. A whole string
// shares all three, so it becomes one draw call.
namespace {

GLuint g_ui_vbo = 0;
GLuint g_batch_program = 0;
GLuint g_batch_texture = 0;
float  g_batch_color[4] = {0, 0, 0, 0};
std::vector<GLfloat> g_batch_verts;   // x,y,u,v per vertex, 6 vertices per quad

void ui_flush()
{
    if (g_batch_verts.empty()) return;

    if (!g_ui_vbo) glGenBuffers(1, &g_ui_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g_ui_vbo);
    glBufferData(GL_ARRAY_BUFFER, GLsizeiptr(g_batch_verts.size() * sizeof(GLfloat)),
                 g_batch_verts.data(), GL_STREAM_DRAW);

    const bool textured = g_batch_program == g_img_program;
    glUseProgram(g_batch_program);
    if (textured) {
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, g_batch_texture);
        glUniform1i(g_img_u_tex, 0);
        glUniform4f(g_img_u_color, g_batch_color[0], g_batch_color[1], g_batch_color[2], g_batch_color[3]);
    } else {
        glUniform4f(g_flat_u_color, g_batch_color[0], g_batch_color[1], g_batch_color[2], g_batch_color[3]);
    }

    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    const GLsizei stride = 4 * sizeof(GLfloat);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, (const void *)0);
    if (textured) {
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride, (const void *)(2 * sizeof(GLfloat)));
    }

    glDrawArrays(GL_TRIANGLES, 0, GLsizei(g_batch_verts.size() / 4));

    if (textured) glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    g_batch_verts.clear();
}

void ui_begin(GLuint program, GLuint texture, float r, float g, float b, float a)
{
    const bool same = program == g_batch_program && texture == g_batch_texture &&
                      r == g_batch_color[0] && g == g_batch_color[1] &&
                      b == g_batch_color[2] && a == g_batch_color[3];
    if (!same) {
        ui_flush();
        g_batch_program = program;
        g_batch_texture = texture;
        g_batch_color[0] = r; g_batch_color[1] = g; g_batch_color[2] = b; g_batch_color[3] = a;
    }
}

void ui_push_quad(float x0, float y0, float x1, float y1,
                  float s0, float t0, float s1, float t1)
{
    const GLfloat q[6][4] = {
        {x0, y0, s0, t0}, {x1, y0, s1, t0}, {x0, y1, s0, t1},
        {x1, y0, s1, t0}, {x1, y1, s1, t1}, {x0, y1, s0, t1},
    };
    g_batch_verts.insert(g_batch_verts.end(), &q[0][0], &q[0][0] + 24);
}

} // namespace

void flush_ui()
{
    ui_flush();
}

void draw_ui_filled_rect(float x, float y, float w, float h,
                         float r, float g, float b, float a)
{
    // O engine ja aplicou ScrPlace_ApplyRect antes de R_AddCmdDrawStretchPic,
    // entao as coords aqui ja estao no espaco do display fisico (pixels).
    // NDC OpenGL = -1..1 com Y crescendo pra cima.
    const float displayW = float(g_viewport_w);
    const float displayH = float(g_viewport_h);
    auto to_ndc_x = [&](float vx) { return (vx / displayW) * 2.0f - 1.0f; };
    auto to_ndc_y = [&](float vy) { return 1.0f - (vy / displayH) * 2.0f; };

    ui_begin(g_flat_program, 0, r, g, b, a);
    ui_push_quad(to_ndc_x(x), to_ndc_y(y), to_ndc_x(x + w), to_ndc_y(y + h),
                 0.0f, 0.0f, 1.0f, 1.0f);
}

void draw_ui_textured_rect(float x, float y, float w, float h,
                           float s0, float t0, float s1, float t1,
                           unsigned int texture,
                           float r, float g, float b, float a)
{
    const float displayW = float(g_viewport_w);
    const float displayH = float(g_viewport_h);
    auto to_ndc_x = [&](float vx) { return (vx / displayW) * 2.0f - 1.0f; };
    auto to_ndc_y = [&](float vy) { return 1.0f - (vy / displayH) * 2.0f; };

    ui_begin(g_img_program, texture, r, g, b, a);
    ui_push_quad(to_ndc_x(x), to_ndc_y(y), to_ndc_x(x + w), to_ndc_y(y + h), s0, t0, s1, t1);
}

void render_frame(float time_seconds)
{
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    const float aspect = float(g_viewport_w) / float(g_viewport_h);
    const glm::mat4 proj = glm::perspective(glm::radians(60.0f), aspect, 0.1f, 100.0f);
    const glm::mat4 view = glm::lookAt(
        glm::vec3(0.0f, 0.0f, 3.0f),  // camera 3 unidades atras
        glm::vec3(0.0f, 0.0f, 0.0f),  // olhando pra origem
        glm::vec3(0.0f, 1.0f, 0.0f)); // up = +Y
    glm::mat4 model(1.0f);
    model = glm::rotate(model, time_seconds * 0.7f, glm::vec3(0.0f, 1.0f, 0.0f));
    model = glm::rotate(model, time_seconds * 0.5f, glm::vec3(1.0f, 0.0f, 0.0f));
    const glm::mat4 mvp = proj * view * model;

    glUseProgram(g_program);
    glUniformMatrix4fv(g_u_mvp, 1, GL_FALSE, &mvp[0][0]);

    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat), CUBE_VERTS);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat), CUBE_VERTS + 3);
    glDrawElements(GL_TRIANGLES,
                   sizeof(CUBE_INDICES) / sizeof(CUBE_INDICES[0]),
                   GL_UNSIGNED_SHORT,
                   CUBE_INDICES);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(0);
}

void shutdown()
{
    if (g_program) {
        glDeleteProgram(g_program);
        g_program = 0;
    }
}

} // namespace gfx_gl
