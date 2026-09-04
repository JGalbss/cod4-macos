#pragma once

// Renderer GLES2 minimal, agnostico de windowing. O caller (switch_main.cpp
// no Switch, futuramente posix gl-main no desktop) e responsavel por criar
// o contexto GL antes de chamar gl_renderer_init.
//
// Estado atual: triangulo demo girando. API vai crescer pra incluir camera,
// buffers de vertice nomeados, texturas, materiais etc. — sem mudar o
// contrato basico de init/begin_frame/end_frame/shutdown.

namespace gfx_gl {

// Carrega shaders, cria program e VAO/VBO equivalentes. Requer um contexto
// GL ativo (eglMakeCurrent ja chamado).
bool init();

// Limpa o backbuffer e desenha o conteudo do frame atual. `time_seconds`
// vem do caller — o renderer nao mede tempo proprio pra deixar facil
// pausar/reescalar.
void render_frame(float time_seconds);

// Libera recursos GL. Deve ser chamado enquanto o contexto ainda esta
// ativo, antes do shutdown do windowing layer.
void shutdown();

// Atualiza o viewport quando a janela muda (handheld <-> docked no Switch,
// resize no desktop).
void set_viewport(int width, int height);

// Permite o port do CoD4 substituir a cor de clear do demo cube pelo que
// o engine pediu via RC_CLEAR_SCREEN. Tomado em conta no proximo
// render_frame.
void apply_clear_color(float r, float g, float b, float a);

// Aplica o clear na hora — usado pelo dispatcher do CoD4 render queue,
// que faz RC_CLEAR_SCREEN + draws na mesma chamada e precisa ver os
// resultados ANTES dos draws.
void clear_now(float r, float g, float b, float a);

// Desenha um retangulo preenchido em coordenadas de UI do CoD4 (640x480
// virtual canvas, origem top-left). Usado pra implementar RC_STRETCH_PIC
// quando o material e o branco/default placeholder.
void draw_ui_filled_rect(float x, float y, float w, float h,
                         float r, float g, float b, float a);

// Desenha um quad texturizado em coordenadas de tela fisica. Usado por
// RC_STRETCH_PIC quando o material tem um color map carregado; (s0,t0)-(s1,t1)
// sao as UVs que o comando trouxe.
void draw_ui_textured_rect(float x, float y, float w, float h,
                           float s0, float t0, float s1, float t1,
                           unsigned int texture,
                           float r, float g, float b, float a);

// Desenha string ASCII com a font 8x8 embutida. (x,y) e o baseline do
// primeiro char em pixels da tela fisica. Usado por RC_DRAW_TEXT_2D.
void draw_ui_text(float x, float y, const char *text,
                  float charW, float charH,
                  float r, float g, float b, float a);

// Emite os quads acumulados. O caller chama uma vez por frame, antes do swap.
void flush_ui();

} // namespace gfx_gl
