# === Switch target ================================================================
# Cross-compile do esqueleto Fase 1 para Nintendo Switch via devkitA64 + libnx.
# Configure com:
#   cmake -B build-switch -S . \
#         -DCMAKE_TOOLCHAIN_FILE=$DEVKITPRO/cmake/Switch.cmake
#   cmake --build build-switch
# Saida: bin/switch/kisak_switch.nro (homebrew NRO format)
#
# Por ora reusa as mesmas fontes do target POSIX — kisak_compat.h e o
# arquivo posix_main.cpp ja sao agnosticos a Switch (libnx fornece main).
# Ver docs/SWITCH_PORT.md para o roadmap.

message(STATUS "[KisakCOD/switch] Building Switch (devkitA64) skeleton target")

if(NOT NINTENDO_SWITCH)
    message(FATAL_ERROR
        "scripts/switch nao deve ser ativado sem o toolchain Switch. "
        "Use -DCMAKE_TOOLCHAIN_FILE=$ENV{DEVKITPRO}/cmake/Switch.cmake")
endif()

set(SWITCH_SOURCES
    "${SRC_DIR}/switch/switch_main.cpp"
    "${SRC_DIR}/switch/switch_renderer_init.cpp"
    "${SRC_DIR}/switch/switch_zone_inspect.cpp"
    "${SRC_DIR}/switch/switch_load_fastfile.cpp"
    "${SRC_DIR}/gfx_gl/gl_renderer.cpp"
    "${SRC_DIR}/posix/posix_assert.cpp"
    "${SRC_DIR}/posix/posix_stubs.cpp"
    "${SRC_DIR}/posix/posix_backbone_stubs.cpp"
)

# Same files validated as portable on the POSIX target.
set(UNIVERSAL_PORTABLE_SOURCES
    "${SRC_DIR}/universal/aabbtree.cpp"
    "${SRC_DIR}/universal/base64.cpp"
    "${SRC_DIR}/universal/com_constantconfigstrings.cpp"
    "${SRC_DIR}/universal/com_convexhull.cpp"
    "${SRC_DIR}/universal/com_files.cpp"
    "${SRC_DIR}/universal/com_math.cpp"
    "${SRC_DIR}/universal/com_math_anglevectors.cpp"
    "${SRC_DIR}/universal/com_shared.cpp"
    "${SRC_DIR}/universal/com_sndalias_load_obj.cpp"
    "${SRC_DIR}/universal/physicalmemory.cpp"
    "${SRC_DIR}/universal/pool_allocator.cpp"
    "${SRC_DIR}/universal/q_shared.cpp"
    "${SRC_DIR}/universal/surfaceflags.cpp"
    "${SRC_DIR}/universal/dvar.cpp"
    "${SRC_DIR}/universal/dvar_cmds.cpp"
    "${SRC_DIR}/universal/com_loadutils.cpp"
    "${SRC_DIR}/universal/com_memory.cpp"
    "${SRC_DIR}/universal/fft.cpp"
    "${SRC_DIR}/universal/com_stringtable.cpp"
    "${SRC_DIR}/universal/memfile.cpp"
    "${SRC_DIR}/universal/profile.cpp"
    "${SRC_DIR}/universal/q_parse.cpp"
)

set(COMMON_PORTABLE_SOURCES
    "${SRC_DIR}/buildnumber.cpp"
    # brush_edges.cpp: compiles clean on clang, but GCC's -Warray-bounds
    # flags hex-rays-style `(*xyz)[3*k]` indexing. Needs signature
    # refactor before it lands on Switch (devkitA64 GCC).
)

set(QCOMMON_PORTABLE_SOURCES
    "${SRC_DIR}/qcommon/cm_load.cpp"
    "${SRC_DIR}/qcommon/cm_load_obj.cpp"
    "${SRC_DIR}/qcommon/cm_mesh.cpp"
    "${SRC_DIR}/qcommon/cm_showcollision.cpp"
    "${SRC_DIR}/qcommon/cm_staticmodel.cpp"
    "${SRC_DIR}/qcommon/cm_test.cpp"
    "${SRC_DIR}/qcommon/cm_trace.cpp"
    "${SRC_DIR}/qcommon/cm_tracebox.cpp"
    "${SRC_DIR}/qcommon/cmd.cpp"
    "${SRC_DIR}/qcommon/com_bsp.cpp"
    "${SRC_DIR}/qcommon/com_bsp_load_obj.cpp"
    "${SRC_DIR}/qcommon/com_fileaccess.cpp"
    "${SRC_DIR}/qcommon/com_pack.cpp"
    "${SRC_DIR}/qcommon/com_playerprofile.cpp"
    "${SRC_DIR}/qcommon/com_profilemapload.cpp"
    "${SRC_DIR}/qcommon/cm_world.cpp"
    "${SRC_DIR}/qcommon/common.cpp"
    "${SRC_DIR}/qcommon/dl_main.cpp"
    "${SRC_DIR}/qcommon/dobj_management.cpp"
    "${SRC_DIR}/qcommon/files.cpp"
    "${SRC_DIR}/qcommon/graph.cpp"
    "${SRC_DIR}/qcommon/huffman.cpp"
    "${SRC_DIR}/qcommon/md4.cpp"
    "${SRC_DIR}/qcommon/mem_track.cpp"
    "${SRC_DIR}/qcommon/msg_mp.cpp"
    "${SRC_DIR}/qcommon/net_chan_mp.cpp"
    "${SRC_DIR}/qcommon/statmonitor.cpp"
    "${SRC_DIR}/qcommon/sv_msg_write_mp.cpp"
    "${SRC_DIR}/qcommon/unzip.cpp"
    # qcommon/threads.cpp deliberately skipped: 934-line Win32-only threading.
    # The single-threaded port uses pthread-backed Sys_* stubs in
    # posix/posix_stubs.cpp + posix_backbone_stubs.cpp instead.
)

set(SCRIPT_PORTABLE_SOURCES
    "${SRC_DIR}/script/scr_animtree.cpp"
    "${SRC_DIR}/script/scr_compiler2.cpp"
    "${SRC_DIR}/script/scr_const.cpp"
    "${SRC_DIR}/script/scr_vm.cpp"
    "${SRC_DIR}/script/scr_evaluate.cpp"
    "${SRC_DIR}/script/scr_main.cpp"
    "${SRC_DIR}/script/scr_memorytree.cpp"
    "${SRC_DIR}/script/scr_parser.cpp"
    "${SRC_DIR}/script/scr_parsetree.cpp"
    "${SRC_DIR}/script/scr_stringlist.cpp"
    "${SRC_DIR}/script/scr_variable.cpp"
    "${SRC_DIR}/script/scr_yacc2.cpp"
)

set(GFX_PORTABLE_SOURCES
    "${SRC_DIR}/gfx_d3d/r_cmdbuf.cpp"
    "${SRC_DIR}/gfx_d3d/r_debug_alloc.cpp"
    "${SRC_DIR}/gfx_d3d/r_devgui.cpp"
    "${SRC_DIR}/gfx_d3d/r_cmds.cpp"
    "${SRC_DIR}/gfx_d3d/r_debug.cpp"
    "${SRC_DIR}/gfx_d3d/r_material_override.cpp"
    "${SRC_DIR}/gfx_d3d/r_dobj_skin.cpp"
    "${SRC_DIR}/gfx_d3d/r_dpvs_dynmodel.cpp"
    "${SRC_DIR}/gfx_d3d/r_model_lighting.cpp"
    "${SRC_DIR}/gfx_d3d/r_model_pose.cpp"
    "${SRC_DIR}/gfx_d3d/r_model_skin.cpp"
    "${SRC_DIR}/gfx_d3d/r_outdoor.cpp"
    "${SRC_DIR}/gfx_d3d/r_dpvs_entity.cpp"
    "${SRC_DIR}/gfx_d3d/r_dpvs_sceneent.cpp"
    "${SRC_DIR}/gfx_d3d/r_dpvs_static.cpp"
    "${SRC_DIR}/gfx_d3d/r_draw_method.cpp"
    "${SRC_DIR}/gfx_d3d/r_drawsurf.cpp"
    "${SRC_DIR}/gfx_d3d/r_dvars.cpp"
    "${SRC_DIR}/gfx_d3d/r_draw_pixelshader.cpp"
    "${SRC_DIR}/gfx_d3d/r_fog.cpp"
    "${SRC_DIR}/gfx_d3d/r_font.cpp"
    "${SRC_DIR}/gfx_d3d/r_image.cpp"
    "${SRC_DIR}/gfx_d3d/r_image_load_common.cpp"
    "${SRC_DIR}/gfx_d3d/r_image_load_obj.cpp"
    "${SRC_DIR}/gfx_d3d/r_image_utils.cpp"
    "${SRC_DIR}/gfx_d3d/r_image_wavelet.cpp"
    "${SRC_DIR}/gfx_d3d/r_imagedecode.cpp"
    "${SRC_DIR}/gfx_d3d/r_light.cpp"
    "${SRC_DIR}/gfx_d3d/r_light_load_obj.cpp"
    "${SRC_DIR}/gfx_d3d/r_warn.cpp"
    "${SRC_DIR}/gfx_d3d/r_water.cpp"
    "${SRC_DIR}/gfx_d3d/r_water_load_obj.cpp"
    "${SRC_DIR}/gfx_d3d/r_workercmds.cpp"
    "${SRC_DIR}/gfx_d3d/r_workercmds_common.cpp"
    "${SRC_DIR}/gfx_d3d/r_model.cpp"
    "${SRC_DIR}/gfx_d3d/r_buffers.cpp"
    "${SRC_DIR}/gfx_d3d/r_add_bsp.cpp"
    "${SRC_DIR}/gfx_d3d/r_bsp.cpp"
    "${SRC_DIR}/gfx_d3d/r_add_cmdbuf.cpp"
    "${SRC_DIR}/gfx_d3d/r_add_staticmodel.cpp"
    "${SRC_DIR}/gfx_d3d/r_draw_bsp.cpp"
    "${SRC_DIR}/gfx_d3d/r_draw_lit.cpp"
    "${SRC_DIR}/gfx_d3d/r_draw_material.cpp"
    "${SRC_DIR}/gfx_d3d/r_draw_shadowable_light.cpp"
    "${SRC_DIR}/gfx_d3d/r_draw_staticmodel.cpp"
    "${SRC_DIR}/gfx_d3d/r_draw_sunshadow.cpp"
    "${SRC_DIR}/gfx_d3d/r_draw_xmodel.cpp"
    "${SRC_DIR}/gfx_d3d/r_marks.cpp"
    "${SRC_DIR}/gfx_d3d/r_material.cpp"
    "${SRC_DIR}/gfx_d3d/r_rendercmds.cpp"
    "${SRC_DIR}/gfx_d3d/r_rendertarget.cpp"
    "${SRC_DIR}/gfx_d3d/r_scene.cpp"
    "${SRC_DIR}/gfx_d3d/r_dpvs.cpp"
    "${SRC_DIR}/gfx_d3d/r_meshdata.cpp"
    "${SRC_DIR}/gfx_d3d/r_pretess.cpp"
    "${SRC_DIR}/gfx_d3d/r_reflection_probe.cpp"
    "${SRC_DIR}/gfx_d3d/r_setstate_d3d.cpp"
    "${SRC_DIR}/gfx_d3d/r_shade.cpp"
    "${SRC_DIR}/gfx_d3d/r_shadowcookie.cpp"
    "${SRC_DIR}/gfx_d3d/r_state_utils.cpp"
    "${SRC_DIR}/gfx_d3d/r_sky.cpp"
    "${SRC_DIR}/gfx_d3d/r_spotshadow.cpp"
    "${SRC_DIR}/gfx_d3d/r_state.cpp"
    "${SRC_DIR}/gfx_d3d/r_sunshadow.cpp"
    "${SRC_DIR}/gfx_d3d/r_pixelcost_load_obj.cpp"
    "${SRC_DIR}/gfx_d3d/r_primarylights.cpp"
    "${SRC_DIR}/gfx_d3d/r_utils.cpp"
    "${SRC_DIR}/gfx_d3d/r_reflection_probe_load_obj.cpp"
    "${SRC_DIR}/gfx_d3d/r_staticmodel.cpp"
    "${SRC_DIR}/gfx_d3d/r_xsurface.cpp"
    "${SRC_DIR}/gfx_d3d/rb_debug.cpp"
    "${SRC_DIR}/gfx_d3d/rb_backend.cpp"
    "${SRC_DIR}/gfx_d3d/rb_depthprepass.cpp"
    "${SRC_DIR}/gfx_d3d/rb_draw3d.cpp"
    "${SRC_DIR}/gfx_d3d/rb_fog.cpp"
    "${SRC_DIR}/gfx_d3d/rb_imagetouch.cpp"
    "${SRC_DIR}/gfx_d3d/rb_showcollision.cpp"
    "${SRC_DIR}/gfx_d3d/rb_sky.cpp"
    "${SRC_DIR}/gfx_d3d/rb_spotshadow.cpp"
    "${SRC_DIR}/gfx_d3d/rb_sunshadow.cpp"
    "${SRC_DIR}/gfx_d3d/rb_shade.cpp"
    "${SRC_DIR}/gfx_d3d/rb_state.cpp"
    "${SRC_DIR}/gfx_d3d/rb_uploadshaders.cpp"
    "${SRC_DIR}/gfx_d3d/rb_pixelcost.cpp"
    "${SRC_DIR}/gfx_d3d/rb_drawprofile.cpp"
    "${SRC_DIR}/gfx_d3d/rb_imagefilter.cpp"
    "${SRC_DIR}/gfx_d3d/rb_light.cpp"
    "${SRC_DIR}/gfx_d3d/rb_logfile.cpp"
    "${SRC_DIR}/gfx_d3d/rb_postfx.cpp"
    "${SRC_DIR}/gfx_d3d/rb_shadowcookie.cpp"
    "${SRC_DIR}/gfx_d3d/rb_stats.cpp"
    "${SRC_DIR}/gfx_d3d/rb_tess.cpp"
)

set(EFFECTSCORE_PORTABLE_SOURCES
    "${SRC_DIR}/EffectsCore/fx_archive.cpp"
    "${SRC_DIR}/EffectsCore/fx_beam.cpp"
    "${SRC_DIR}/EffectsCore/fx_convert.cpp"
    "${SRC_DIR}/EffectsCore/fx_draw.cpp"
    "${SRC_DIR}/EffectsCore/fx_dvars.cpp"
    "${SRC_DIR}/EffectsCore/fx_graph.cpp"
    "${SRC_DIR}/EffectsCore/fx_load_obj.cpp"
    "${SRC_DIR}/EffectsCore/fx_marks.cpp"
    "${SRC_DIR}/EffectsCore/fx_postlight.cpp"
    "${SRC_DIR}/EffectsCore/fx_profile.cpp"
    "${SRC_DIR}/EffectsCore/fx_random.cpp"
    "${SRC_DIR}/EffectsCore/fx_sort.cpp"
    "${SRC_DIR}/EffectsCore/fx_sprite.cpp"
    "${SRC_DIR}/EffectsCore/fx_system.cpp"
    "${SRC_DIR}/EffectsCore/fx_update.cpp"
    "${SRC_DIR}/EffectsCore/fx_update_util.cpp"
    "${SRC_DIR}/EffectsCore/fxcurve.cpp"
)

set(RAGDOLL_PORTABLE_SOURCES
    "${SRC_DIR}/ragdoll/ragdoll.cpp"
    "${SRC_DIR}/ragdoll/ragdoll_controller.cpp"
    "${SRC_DIR}/ragdoll/ragdoll_quat.cpp"
    "${SRC_DIR}/ragdoll/ragdoll_update.cpp"
)

set(DYNENTITY_PORTABLE_SOURCES
    "${SRC_DIR}/DynEntity/DynEntity_client.cpp"
    "${SRC_DIR}/DynEntity/DynEntity_coll.cpp"
    "${SRC_DIR}/DynEntity/DynEntity_load_obj.cpp"
    "${SRC_DIR}/DynEntity/DynEntity_pieces.cpp"
)

set(DATABASE_PORTABLE_SOURCES
    "${SRC_DIR}/database/db_assetnames.cpp"
    "${SRC_DIR}/database/db_auth.cpp"
    "${SRC_DIR}/database/db_load.cpp"
    "${SRC_DIR}/database/db_registry.cpp"
    "${SRC_DIR}/database/db_memory.cpp"
    "${SRC_DIR}/database/db_stream.cpp"
    "${SRC_DIR}/database/db_stream_load.cpp"
    "${SRC_DIR}/database/db_stringtable_load.cpp"
)

set(DEVGUI_PORTABLE_SOURCES
    "${SRC_DIR}/devgui/devgui.cpp"
    "${SRC_DIR}/devgui/devgui_input.cpp"
    "${SRC_DIR}/devgui/devgui_util.cpp"
)

set(AIMASSIST_PORTABLE_SOURCES
    "${SRC_DIR}/aim_assist/aim_assist.cpp"
    "${SRC_DIR}/aim_assist/aim_target_mp.cpp"
)

set(UI_PORTABLE_SOURCES
    "${SRC_DIR}/ui/ui_atoms.cpp"
    "${SRC_DIR}/ui/ui_expressions.cpp"
    "${SRC_DIR}/ui/ui_expressions_logicfunctions.cpp"
    "${SRC_DIR}/ui/ui_shared.cpp"
    "${SRC_DIR}/ui/ui_shared_obj.cpp"
    "${SRC_DIR}/ui/ui_localvars.cpp"
    "${SRC_DIR}/ui/ui_utils.cpp"
    "${SRC_DIR}/ui_mp/ui_gameinfo_mp.cpp"
    "${SRC_DIR}/ui_mp/ui_main_mp.cpp"
)

set(PHYSICS_PORTABLE_SOURCES
    "${SRC_DIR}/physics/ode/collision_util.cpp"
    "${SRC_DIR}/physics/ode/error.cpp"
    "${SRC_DIR}/physics/ode/lcp.cpp"
    "${SRC_DIR}/physics/ode/fastdot.c"
    "${SRC_DIR}/physics/ode/fastldlt.c"
    "${SRC_DIR}/physics/ode/fastlsolve.c"
    "${SRC_DIR}/physics/ode/fastltsolve.c"
    "${SRC_DIR}/physics/ode/mass.cpp"
    "${SRC_DIR}/physics/ode/matrix.cpp"
    "${SRC_DIR}/physics/ode/odemath.cpp"
    "${SRC_DIR}/physics/ode/odemisc.cpp"
    "${SRC_DIR}/physics/ode/rotation.cpp"
    "${SRC_DIR}/physics/ode/timer.cpp"
    "${SRC_DIR}/physics/phys_coll_capsulebrush.cpp"
    "${SRC_DIR}/physics/phys_coll_cylinderbrush.cpp"
    "${SRC_DIR}/physics/phys_contacts.cpp"
    "${SRC_DIR}/physics/physpreset_load_obj.cpp"
)

set(STRINGED_PORTABLE_SOURCES
    "${SRC_DIR}/stringed/stringed_hooks.cpp"
    "${SRC_DIR}/stringed/stringed_ingame.cpp"
)

set(SERVER_PORTABLE_SOURCES
    "${SRC_DIR}/server/sv_game.cpp"
    "${SRC_DIR}/server/sv_world.cpp"
    "${SRC_DIR}/server_mp/sv_archive_mp.cpp"
    "${SRC_DIR}/server_mp/sv_ccmds_mp.cpp"
    "${SRC_DIR}/server_mp/sv_client_mp.cpp"
    "${SRC_DIR}/server_mp/sv_init_mp.cpp"
    "${SRC_DIR}/server_mp/sv_main_mp.cpp"
    "${SRC_DIR}/server_mp/sv_snapshot_mp.cpp"
    "${SRC_DIR}/server_mp/sv_snapshot_profile_mp.cpp"
    "${SRC_DIR}/server_mp/sv_voice_mp.cpp"
    "${SRC_DIR}/server_mp/sv_main_pc_mp.cpp"
    "${SRC_DIR}/server_mp/sv_net_chan_mp.cpp"
    "${SRC_DIR}/server_mp/ucmds.cpp"
)

set(SOUND_PORTABLE_SOURCES
    "${SRC_DIR}/sound/snd_driver_load_obj.cpp"
    "${SRC_DIR}/sound/snd_utils.cpp"
)

set(CGAME_PORTABLE_SOURCES
    "${SRC_DIR}/cgame/cg_camerashake.cpp"
    "${SRC_DIR}/cgame/cg_colltree.cpp"
    "${SRC_DIR}/cgame/cg_compass.cpp"
    "${SRC_DIR}/cgame/cg_draw_debug.cpp"
    "${SRC_DIR}/cgame/cg_draw_indicators.cpp"
    "${SRC_DIR}/cgame/cg_draw_reticles.cpp"
    "${SRC_DIR}/cgame/cg_drawtools.cpp"
    "${SRC_DIR}/cgame/cg_effects_load_obj.cpp"
    "${SRC_DIR}/cgame/cg_event.cpp"
    "${SRC_DIR}/cgame/cg_hudelem.cpp"
    "${SRC_DIR}/cgame/cg_info.cpp"
    "${SRC_DIR}/cgame/cg_laser.cpp"
    "${SRC_DIR}/cgame/cg_localents.cpp"
    "${SRC_DIR}/cgame/cg_playerstate.cpp"
    "${SRC_DIR}/cgame/cg_pose_utils.cpp"
    "${SRC_DIR}/cgame/cg_shellshock.cpp"
    "${SRC_DIR}/cgame/cg_ammocounter.cpp"
    "${SRC_DIR}/cgame/cg_visionsets.cpp"
    "${SRC_DIR}/cgame/cg_weapons.cpp"
    "${SRC_DIR}/cgame/cg_world.cpp"
    "${SRC_DIR}/cgame/offhandweapons.cpp"
    "${SRC_DIR}/cgame_mp/cg_animtree_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_client_side_effects_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_draw_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_ents_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_compassfriendlies_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_consolecmds_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_draw_net_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_gamepad.cpp"
    "${SRC_DIR}/cgame_mp/cg_main_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_newDraw_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_players_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_predict_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_scoreboard_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_servercmds_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_snapshot_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_vehicles_mp.cpp"
    "${SRC_DIR}/cgame_mp/cg_view_mp.cpp"
    "${SRC_DIR}/cgame_mp/dedicated_cgame.cpp"
)

set(CLIENT_PORTABLE_SOURCES
    "${SRC_DIR}/client/cl_console.cpp"
    "${SRC_DIR}/client/cl_debugdata.cpp"
    "${SRC_DIR}/client/cl_devgui.cpp"
    "${SRC_DIR}/client/cl_keys.cpp"
    "${SRC_DIR}/client/con_channels.cpp"
    "${SRC_DIR}/client/screen_placement.cpp"
    "${SRC_DIR}/client_mp/cl_cgame_mp.cpp"
    "${SRC_DIR}/client_mp/cl_input.cpp"
    "${SRC_DIR}/client_mp/cl_main_mp.cpp"
    "${SRC_DIR}/client_mp/cl_main_pc_mp.cpp"
    "${SRC_DIR}/client_mp/cl_parse_mp.cpp"
    "${SRC_DIR}/client_mp/cl_net_chan_mp.cpp"
    "${SRC_DIR}/client_mp/cl_pose_mp.cpp"
    "${SRC_DIR}/client_mp/cl_scrn_mp.cpp"
    "${SRC_DIR}/client_mp/cl_ui_mp.cpp"
    "${SRC_DIR}/client_mp/cl_rank.cpp"
    "${SRC_DIR}/client_mp/cl_voice.cpp"
)

set(GAME_PORTABLE_SOURCES
    "${SRC_DIR}/game/bullet.cpp"
    "${SRC_DIR}/game/enthandle.cpp"
    "${SRC_DIR}/game/g_client_fields.cpp"
    "${SRC_DIR}/game/g_bsp.cpp"
    "${SRC_DIR}/game/g_debug.cpp"
    "${SRC_DIR}/game/g_helicopter.cpp"
    "${SRC_DIR}/game/g_hudelem.cpp"
    "${SRC_DIR}/game/g_items.cpp"
    "${SRC_DIR}/game/g_load_utils.cpp"
    "${SRC_DIR}/game/g_missile.cpp"
    "${SRC_DIR}/game/g_scr_vehicle.cpp"
    "${SRC_DIR}/game/g_mover.cpp"
    "${SRC_DIR}/game/g_scr_mover.cpp"
    "${SRC_DIR}/game/g_weapon.cpp"
    "${SRC_DIR}/game/g_svcmds.cpp"
    "${SRC_DIR}/game/g_weapon_load_obj.cpp"
    "${SRC_DIR}/game_mp/g_active_mp.cpp"
    "${SRC_DIR}/game_mp/g_client_mp.cpp"
    "${SRC_DIR}/game_mp/g_client_script_cmd_mp.cpp"
    "${SRC_DIR}/game_mp/g_cmds_mp.cpp"
    "${SRC_DIR}/game_mp/g_combat_mp.cpp"
    "${SRC_DIR}/game_mp/g_main_mp.cpp"
    "${SRC_DIR}/game_mp/g_misc_mp.cpp"
    "${SRC_DIR}/game_mp/g_player_corpse_mp.cpp"
    "${SRC_DIR}/game_mp/g_scr_helicopter.cpp"
    "${SRC_DIR}/game_mp/g_scr_main_mp.cpp"
    "${SRC_DIR}/game_mp/g_spawn_mp.cpp"
    "${SRC_DIR}/game_mp/g_trigger_mp.cpp"
    "${SRC_DIR}/game_mp/g_utils_mp.cpp"
    "${SRC_DIR}/game_mp/g_vehicles_mp.cpp"
    "${SRC_DIR}/game_mp/player_use_mp.cpp"
)

set(XANIM_PORTABLE_SOURCES
    "${SRC_DIR}/xanim/dobj.cpp"
    "${SRC_DIR}/xanim/dobj_skel.cpp"
    "${SRC_DIR}/xanim/dobj_utils.cpp"
    "${SRC_DIR}/xanim/xanim.cpp"
    "${SRC_DIR}/xanim/xanim_calc.cpp"
    "${SRC_DIR}/xanim/xanim_load_obj.cpp"
    "${SRC_DIR}/xanim/xmodel_load_obj.cpp"
    "${SRC_DIR}/xanim/xmodel_load_phys_collmap.cpp"
    "${SRC_DIR}/xanim/xmodel.cpp"
    "${SRC_DIR}/xanim/xmodel_utils.cpp"
)

set(BGAME_PORTABLE_SOURCES
    "${SRC_DIR}/bgame/bg_animation_mp.cpp"
    "${SRC_DIR}/bgame/bg_pmove.cpp"
    "${SRC_DIR}/bgame/bg_weapons.cpp"
    "${SRC_DIR}/bgame/bg_misc.cpp"
    "${SRC_DIR}/bgame/bg_jump.cpp"
    "${SRC_DIR}/bgame/bg_mantle.cpp"
    "${SRC_DIR}/bgame/bg_misctables.cpp"
    "${SRC_DIR}/bgame/bg_perks_mp.cpp"
    "${SRC_DIR}/bgame/bg_slidemove.cpp"
    "${SRC_DIR}/bgame/bg_vehicles_mp.cpp"
    "${SRC_DIR}/bgame/bg_weapons_load_obj.cpp"
)

add_executable(kisak_switch
    ${SWITCH_SOURCES}
    ${UNIVERSAL_PORTABLE_SOURCES}
    ${QCOMMON_PORTABLE_SOURCES}
    ${COMMON_PORTABLE_SOURCES}
    ${SCRIPT_PORTABLE_SOURCES}
    ${GFX_PORTABLE_SOURCES}
    ${EFFECTSCORE_PORTABLE_SOURCES}
    ${RAGDOLL_PORTABLE_SOURCES}
    ${DYNENTITY_PORTABLE_SOURCES}
    ${XANIM_PORTABLE_SOURCES}
    ${BGAME_PORTABLE_SOURCES}
    ${DATABASE_PORTABLE_SOURCES}
    ${DEVGUI_PORTABLE_SOURCES}
    ${AIMASSIST_PORTABLE_SOURCES}
    ${UI_PORTABLE_SOURCES}
    ${SERVER_PORTABLE_SOURCES}
    ${SOUND_PORTABLE_SOURCES}
    ${CGAME_PORTABLE_SOURCES}
    ${CLIENT_PORTABLE_SOURCES}
    ${GAME_PORTABLE_SOURCES}
    ${PHYSICS_PORTABLE_SOURCES}
    ${STRINGED_PORTABLE_SOURCES}
)

target_include_directories(kisak_switch PRIVATE
    "${SRC_DIR}"
    "${SRC_DIR}/universal"
    "${SRC_DIR}/posix/include_shims" # makes <zlib/zlib.h> resolve to switch-zlib
    "${DEPS_DIR}"                    # makes <ode/ode.h> resolve to deps/ode/ode.h
    # portlibs/switch has EGL/GLES2/zlib/etc — the toolchain only adds libnx
    # by default, portlibs has to be explicit.
    "$ENV{DEVKITPRO}/portlibs/switch/include"
)

target_compile_definitions(kisak_switch PRIVATE KISAK_MP KISAK_NO_FASTFILES)

target_compile_options(kisak_switch PRIVATE
    -Wall
    # Project-wide policy: zero warnings. Any warning must be fixed at the
    # site (explicit casts, parentheses, [[maybe_unused]]) rather than
    # suppressed with -Wno-*. -Werror enforces the policy.
    -Werror
    -include${SRC_DIR}/posix/kisak_compat.h
)

set_target_properties(kisak_switch PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${BIN_DIR}/switch"
)

# Gera o .nro (homebrew NRO) a partir do .elf do target. NACP default e
# icone default sao usados (libnx fornece). Customizar quando o jogo
# estiver jogavel.
# Renderer GLES2 via mesa-nouveau no Switch. Ordem dos -l importa: EGL/GLESv2
# antes de glapi e drm_nouveau pra resolver simbolos no link estatico.
target_link_libraries(kisak_switch PRIVATE
    EGL
    GLESv2
    glapi
    drm_nouveau
    z
)

nx_create_nro(kisak_switch
    OUTPUT  "${BIN_DIR}/switch/kisak_switch.nro"
)
