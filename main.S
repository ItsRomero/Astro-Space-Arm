/* ============================================================================
 * Proyecto : ASTRO SPACE - Videojuego de naves para RP2040 (Raspberry Pi Pico)
 * Archivo  : main.S
 * ----------------------------------------------------------------------------
 * Descripción:
 *   Módulo principal del juego. Contiene:
 *     - La máquina de estados finita (FSM): MENÚ -> JUEGO -> GAME OVER.
 *     - La "física" 2D: movimiento de la nave, del láser y de los enemigos.
 *     - Detección de colisiones por rectángulos alineados a los ejes (AABB).
 *     - Puntuación, vidas y generación pseudoaleatoria de alturas (LFSR).
 *     - Composición de las tres pantallas (menú, partida/HUD y game over).
 *
 * Dependencias (símbolos externos de los otros módulos):
 *   inputs.S : inputs_init, read_adc_x, read_adc_y, read_btn_z_pressed
 *   timer.S  : timer_init, timer_start, timer_stop, timer_check_and_clear_tick
 *   video.S  : video_init, fb_clear, fb_draw_pixel, fb_draw_hline,
 *              fb_draw_sprite, fb_draw_char, fb_draw_string, fb_draw_num3,
 *              oled_flush
 *
 * Convención de llamadas (AAPCS, ARM Procedure Call Standard):
 *   - r0..r3 : argumentos / valor de retorno; la subrutina puede destruirlos.
 *   - r4..r7 : deben conservarse (se guardan con PUSH y se restauran con POP).
 *   - lr     : dirección de retorno; se guarda si la subrutina llama a otra.
 *   - La pila se mantiene alineada a 8 bytes (se apila un número par de
 *     registros; por eso a veces se apila r3 o r4 aunque no se usen).
 *
 * Sistema de coordenadas de la pantalla (128 x 64 píxeles):
 *   (0,0) es la esquina superior izquierda; X crece a la derecha y Y hacia
 *   abajo. Las filas 0..9 están reservadas para el HUD (puntos y vidas).
 * ============================================================================ */

.syntax unified                         /* Sintaxis unificada ARM/Thumb       */
.cpu cortex-m0plus                      /* Núcleo del RP2040 (ARMv6-M)        */
.thumb                                  /* El M0+ solo ejecuta código Thumb   */

/* --- Estados de la Máquina de Estados Finita (FSM) --- */
.equ STATE_MENU,        0               /* Pantalla de título, espera botón Z */
.equ STATE_PLAYING,     1               /* Partida en curso, avanza a 30 Hz   */
.equ STATE_GAMEOVER,    2               /* Fin de partida, espera botón Z     */

/* ============================================================================
 * Variables de estado del videojuego en RAM (.bss)
 * Todas son palabras de 32 bits (4 bytes) para poder usar LDR/STR directos.
 * La sección .bss se pone a cero al arrancar, antes de llamar a game_main.
 * ============================================================================ */
.section .bss
.align 2                                /* Alinear a 4 bytes (2^2)            */
current_game_state:     .space 4                /* Estado actual (0=Menú, 1=Juego, 2=GameOver) */
player_score:          .space 4                /* Puntuación del jugador (0..999) */
remaining_lives:          .space 4                /* Vidas restantes (0..3) */
player_position_x:       .space 4                /* Coordenada X de la nave (limitada a 2..96) */
player_position_y:       .space 4                /* Coordenada Y de la nave (limitada a 12..55) */
laser_position_x:        .space 4                /* Coordenada X del proyectil láser */
laser_position_y:        .space 4                /* Coordenada Y del proyectil láser */
laser_in_flight:   .space 4                /* 1 = Láser en vuelo, 0 = Listo para disparar */
enemy_positions_x:        .space 12               /* Arreglo de 3 palabras: X de los 3 enemigos */
enemy_positions_y:        .space 12               /* Arreglo de 3 palabras: Y de los 3 enemigos */
enemy_height_lfsr_state:      .space 4                /* Estado del LFSR que genera alturas de enemigos */

/* --- Código Principal --- */
.section .text
.align 2

.global game_main                       /* Visible para astro-space-asm.ino */

/* ----------------------------------------------------------------------------
 * Función: game_main
 * Punto de entrada llamado desde setup() en el archivo .ino (enlace C).
 * Inicializa los periféricos y entra en el bucle infinito de la FSM.
 * Parámetros: ninguno | Retorno: nunca regresa.
 * ---------------------------------------------------------------------------- */
.thumb_func
game_main:
    push {r4, lr}                       /* Guardar r4 y lr (2 registros = 8 bytes) */

    /* 1. Inicializar periféricos Bare-Metal (Inputs, Video I2C y Timer NVIC) */
    bl inputs_init                      /* ADC del joystick y GPIO del botón Z */
    bl video_init                       /* I2C0 + pantalla OLED SSD1306 */
    bl timer_init                       /* ALARM1 + vector de interrupción */

    /* 2. Inicializar semilla LFSR y estado inicial en Menú Principal */
    ldr r0, =enemy_height_lfsr_state    /* r0 = dirección de la variable */
    ldr r1, =0xACE1                     /* Semilla clásica no nula del LFSR */
    str r1, [r0, #0]                    /* enemy_height_lfsr_state = 0xACE1 */

    ldr r0, =current_game_state
    movs r1, #STATE_MENU
    str r1, [r0, #0]                    /* current_game_state = MENÚ */

    /* Dibujar pantalla estática inicial del Menú Principal */
    bl render_menu_screen

/* --- Bucle Principal de la Máquina de Estados ---
 * Lee el estado actual y salta al manejador correspondiente. Cada manejador
 * termina con "b main_loop", por lo que este bucle no termina nunca. */
main_loop:
    ldr r0, =current_game_state
    ldr r1, [r0, #0]                    /* r1 = estado actual */

    cmp r1, #STATE_MENU
    beq handle_state_menu               /* Estado 0 -> menú */

    cmp r1, #STATE_PLAYING
    beq handle_state_playing            /* Estado 1 -> partida */

    b handle_state_gameover             /* Cualquier otro valor -> game over */

/* ----------------------------------------------------------------------------
 * Estado 0: MENÚ PRINCIPAL
 * Pantalla inicial estática (ya dibujada); arranca al pulsar el botón Z.
 * ---------------------------------------------------------------------------- */
handle_state_menu:
    bl read_btn_z_pressed               /* r0 = 1 solo en el instante de pulsar */
    cmp r0, #1
    bne main_loop                       /* Sin pulsación: seguir esperando */

    /* Al pulsar Z: inicializar variables de partida, arrancar Timer e ir a PLAYING */
    bl reset_game_state
    bl timer_start                      /* Comienzan los ticks de 30 Hz */

    ldr r0, =current_game_state
    movs r1, #STATE_PLAYING
    str r1, [r0, #0]                    /* current_game_state = JUEGO */
    b main_loop

/* ----------------------------------------------------------------------------
 * Estado 1: JUEGO EN CURSO (Sincronizado por Interrupción de Hardware a ~30 Hz)
 * La ISR del timer solo levanta una bandera; todo el trabajo pesado (lógica y
 * dibujo) se hace aquí, fuera de la interrupción.
 * ---------------------------------------------------------------------------- */
handle_state_playing:
    /* Esperar a que la interrupción de hardware (ALARM1) active frame_tick_pending */
    bl timer_check_and_clear_tick       /* r0 = 1 si hay tick (y lo consume) */
    cmp r0, #0
    beq main_loop                       /* Sin delay loops: espera limpia al evento de IRQ */

    /* Actualizar físicas, colisiones y renderizar el Framebuffer */
    bl update_game_physics
    bl render_game_frame
    b main_loop

/* ----------------------------------------------------------------------------
 * Estado 2: GAME OVER
 * Temporizador de físicas detenido; la pantalla final ya fue dibujada por
 * update_game_physics. Espera el botón Z para reiniciar.
 * ---------------------------------------------------------------------------- */
handle_state_gameover:
    bl read_btn_z_pressed
    cmp r0, #1
    bne main_loop

    /* Al pulsar Z: reiniciar variables de estado, reactivar Timer y jugar */
    bl reset_game_state
    bl timer_start

    ldr r0, =current_game_state
    movs r1, #STATE_PLAYING
    str r1, [r0, #0]
    b main_loop

.ltorg                                  /* Pool de literales para los LDR =... */

/* ----------------------------------------------------------------------------
 * Subrutina: reset_game_state
 * Reinicia todas las variables de la partida en RAM:
 *   puntos = 0, vidas = 3, nave en (10, 32), láser inactivo y
 *   enemigos en (120,16), (155,34) y (190,50).
 * Nota: el estado del LFSR NO se reinicia, así cada partida es distinta.
 * Parámetros: ninguno | Retorno: ninguno.
 * ---------------------------------------------------------------------------- */
.thumb_func
reset_game_state:
    push {r4, lr}

    ldr r0, =player_score
    movs r1, #0
    str r1, [r0, #0]                    /* player_score = 0 */

    ldr r0, =remaining_lives
    movs r1, #3
    str r1, [r0, #0]                    /* remaining_lives = 3 */

    ldr r0, =player_position_x
    movs r1, #10
    str r1, [r0, #0]                    /* Nave X = 10 (lado izquierdo) */

    ldr r0, =player_position_y
    movs r1, #32
    str r1, [r0, #0]                    /* Nave Y = 32 (centro vertical) */

    ldr r0, =laser_in_flight
    movs r1, #0
    str r1, [r0, #0]                    /* Sin láser en pantalla */

    /* Posiciones iniciales escalonadas para los 3 enemigos.
     * X = 155 y X = 190 quedan fuera de la pantalla (>127): entran poco a poco. */
    ldr r0, =enemy_positions_x
    movs r1, #120
    str r1, [r0, #0]                    /* enemigo[0].x = 120 */
    movs r1, #155
    str r1, [r0, #4]                    /* enemigo[1].x = 155 */
    movs r1, #190
    str r1, [r0, #8]                    /* enemigo[2].x = 190 */

    ldr r0, =enemy_positions_y
    movs r1, #16
    str r1, [r0, #0]                    /* enemigo[0].y = 16 */
    movs r1, #34
    str r1, [r0, #4]                    /* enemigo[1].y = 34 */
    movs r1, #50
    str r1, [r0, #8]                    /* enemigo[2].y = 50 */

    pop {r4, pc}                        /* Restaurar r4 y regresar */

/* ----------------------------------------------------------------------------
 * Subrutina: next_random_y
 * Avanza un LFSR de Galois de 16 bits (polinomio 0xB400) y obtiene de él una
 * coordenada Y válida para un enemigo, por debajo del HUD.
 *   nuevo = estado >> 1;  si (estado & 1) entonces nuevo ^= 0xB400
 *   Y     = (nuevo & 31) + 14   ->  rango 14..45
 * Parámetros: ninguno
 * Retorno   : r0 = coordenada Y pseudoaleatoria (14..45)
 * Registros destruidos: r1, r2, r3 (permitido por AAPCS).
 * ---------------------------------------------------------------------------- */
.thumb_func
next_random_y:
    ldr r1, =enemy_height_lfsr_state
    ldr r0, [r1, #0]                    /* r0 = estado actual */
    lsrs r2, r0, #1                     /* r2 = estado >> 1 */
    movs r3, #1
    ands r0, r3                         /* r0 = bit menos significativo */
    beq 1f                              /* Si el bit era 0, no se aplica XOR */
    ldr r3, =0xB400                     /* Máscara de realimentación (taps) */
    eors r2, r3                         /* r2 ^= 0xB400 */
1:
    str r2, [r1, #0]                    /* Guardar nuevo estado */
    movs r0, #0x1F                      /* 0..31 */
    ands r0, r2
    adds r0, r0, #14                    /* Rango Y = 14..45 (bajo la línea del HUD) */
    bx lr                               /* Hoja: no llama a nadie, no apila lr */

/* ----------------------------------------------------------------------------
 * Subrutina: update_game_physics
 * Ejecuta una iteración (un "tick") de la lógica del juego:
 *   1-2. Lee el joystick y mueve la nave dentro de sus límites.
 *   3.   Dispara o mueve el láser (disparo automático, uno a la vez).
 *   4.   Mueve los 3 enemigos y revisa colisiones láser/enemigo y nave/enemigo.
 *   5.   Si las vidas llegan a 0, detiene el timer y muestra GAME OVER.
 * Uso de registros dentro del bucle de enemigos:
 *   r4 = &enemy_positions_x, r5 = &enemy_positions_y,
 *   r6 = desplazamiento en bytes (i*4), r7 = índice del enemigo i.
 * Parámetros: ninguno | Retorno: ninguno.
 * ---------------------------------------------------------------------------- */
.thumb_func
update_game_physics:
    push {r3, r4, r5, r6, r7, lr}       /* 6 registros = 24 bytes (alineado a 8) */

    /* 1. Leer eje X del ADC y mover jugador dentro de límites (2..96) */
    bl read_adc_x                       /* r0 = delta X (-2..+2) */
    ldr r1, =player_position_x
    ldr r2, [r1, #0]
    adds r2, r2, r0                     /* nueva X = X + delta */
    cmp r2, #2
    bge 1f
    movs r2, #2                         /* Límite izquierdo */
1:
    cmp r2, #96
    ble 2f
    movs r2, #96                        /* Límite derecho (la nave no cruza media pantalla) */
2:
    str r2, [r1, #0]

    /* 2. Leer eje Y del ADC y mover jugador dentro de límites (12..55) */
    bl read_adc_y                       /* r0 = delta Y (-2..+2) */
    ldr r1, =player_position_y
    ldr r2, [r1, #0]
    adds r2, r2, r0
    cmp r2, #12
    bge 3f
    movs r2, #12                        /* Límite superior (debajo del HUD) */
3:
    cmp r2, #55
    ble 4f
    movs r2, #55                        /* Límite inferior (55 + 8 = 63, última fila) */
4:
    str r2, [r1, #0]

    /* 3. Actualizar proyectil láser (disparo continuo automático) */
    ldr r4, =laser_in_flight
    ldr r0, [r4, #0]
    cmp r0, #0
    bne laser_move                      /* Ya hay un láser: solo moverlo */

    /* Disparar nuevo proyectil desde el cañón frontal de la nave */
    movs r0, #1
    str r0, [r4, #0]                    /* laser_in_flight = 1 */
    ldr r0, =player_position_x
    ldr r0, [r0, #0]
    adds r0, r0, #8                     /* Sale justo a la derecha del sprite 8x8 */
    ldr r1, =laser_position_x
    str r0, [r1, #0]

    ldr r0, =player_position_y
    ldr r0, [r0, #0]
    adds r0, r0, #3                     /* A media altura de la nave */
    ldr r1, =laser_position_y
    str r0, [r1, #0]
    b enemies_update

laser_move:
    ldr r1, =laser_position_x
    ldr r0, [r1, #0]
    adds r0, r0, #5                     /* Velocidad del láser: 5 px/tick */
    cmp r0, #126
    blt 5f
    movs r0, #0
    str r0, [r4, #0]                    /* Desactivar al salir por la derecha */
    b enemies_update
5:
    str r0, [r1, #0]                    /* Guardar nueva X del láser */

    /* 4. Actualizar los 3 enemigos y verificar colisiones */
enemies_update:
    movs r7, #0                         /* Índice de enemigo i = 0..2 */

enemy_loop:
    lsls r6, r7, #2                     /* Offset en bytes = i * 4 */
    ldr r4, =enemy_positions_x
    ldr r5, =enemy_positions_y

    ldr r0, [r4, r6]                    /* r0 = enemy_positions_x[i] */
    subs r0, r0, #2                     /* Velocidad enemiga: 2 px/tick a la izquierda */
    str r0, [r4, r6]

    /* ¿El enemigo rebasó el borde izquierdo (X <= 0)? -> Pierde 1 vida */
    cmp r0, #0
    bgt check_laser_hit                 /* Comparación con signo: X > 0 sigue vivo */

    bl lose_one_life
    bl next_random_y                    /* Nueva altura aleatoria */
    str r0, [r5, r6]
    movs r0, #128
    str r0, [r4, r6]                    /* Reaparece justo fuera del borde derecho */
    b next_enemy

check_laser_hit:
    /* Verificar colisión Láser vs Enemigo[i] (solo si hay láser activo) */
    ldr r1, =laser_in_flight
    ldr r1, [r1, #0]
    cmp r1, #0
    beq check_player_hit

    ldr r1, =laser_position_x
    ldr r1, [r1, #0]                    /* r1 = laser_position_x */
    ldr r2, [r4, r6]                    /* r2 = enemy_positions_x[i] */

    /* Condición X: laser_position_x + 4 >= enemy_positions_x && laser_position_x <= enemy_positions_x + 8 */
    adds r3, r1, #4
    cmp r3, r2
    blt check_player_hit                /* Láser completamente a la izquierda */
    adds r3, r2, #4
    adds r3, r3, #4                     /* r3 = enemigo.x + 8 (Thumb: inmediato máx. 7 en 3 operandos) */
    cmp r1, r3
    bgt check_player_hit                /* Láser completamente a la derecha */

    /* Condición Y: laser_position_y + 2 >= enemy_positions_y && laser_position_y <= enemy_positions_y + 8 */
    ldr r1, =laser_position_y
    ldr r1, [r1, #0]                    /* r1 = laser_position_y */
    ldr r2, [r5, r6]                    /* r2 = enemy_positions_y[i] */
    adds r3, r1, #2
    cmp r3, r2
    blt check_player_hit                /* Láser por encima del enemigo */
    adds r3, r2, #4
    adds r3, r3, #4                     /* r3 = enemigo.y + 8 */
    cmp r1, r3
    bgt check_player_hit                /* Láser por debajo del enemigo */

    /* ¡Impacto de láser confirmado! Desactivar láser, sumar 10 puntos y reaparecer enemigo */
    ldr r0, =laser_in_flight
    movs r1, #0
    str r1, [r0, #0]

    ldr r0, =player_score
    ldr r1, [r0, #0]
    adds r1, r1, #10                    /* +10 puntos por enemigo */
    ldr r2, =999
    cmp r1, r2
    ble 6f
    movs r1, r2                         /* Saturar en 999 (el HUD solo muestra 3 cifras) */
6:
    str r1, [r0, #0]

    bl next_random_y
    str r0, [r5, r6]                    /* Nueva altura */
    movs r0, #128
    str r0, [r4, r6]                    /* Reaparece a la derecha */
    b next_enemy

check_player_hit:
    /* Verificar colisión AABB Jugador (8x8) vs Enemigo[i] (8x8).
     * Dos cajas se tocan si se solapan en X y también en Y:
     *   A.x + 7 >= B.x  &&  A.x <= B.x + 7  (igual para Y)                */
    ldr r0, =player_position_x
    ldr r0, [r0, #0]                    /* player_position_x */
    ldr r1, [r4, r6]                    /* enemy_positions_x[i] */

    adds r2, r0, #7
    cmp r2, r1
    blt next_enemy                      /* Nave a la izquierda del enemigo */
    adds r2, r1, #7
    cmp r0, r2
    bgt next_enemy                      /* Nave a la derecha del enemigo */

    ldr r0, =player_position_y
    ldr r0, [r0, #0]                    /* player_position_y */
    ldr r1, [r5, r6]                    /* enemy_positions_y[i] */

    adds r2, r0, #7
    cmp r2, r1
    blt next_enemy                      /* Nave por encima */
    adds r2, r1, #7
    cmp r0, r2
    bgt next_enemy                      /* Nave por debajo */

    /* ¡Colisión con el jugador! Restar vida y reposicionar enemigo */
    bl lose_one_life
    bl next_random_y
    str r0, [r5, r6]
    movs r0, #128
    str r0, [r4, r6]

next_enemy:
    adds r7, r7, #1                     /* i++ */
    cmp r7, #3
    blt enemy_loop                      /* Repetir mientras i < 3 */

    /* 5. Verificar condición de fin de partida (remaining_lives == 0) */
    ldr r0, =remaining_lives
    ldr r0, [r0, #0]
    cmp r0, #0
    bgt physics_done                    /* Quedan vidas: terminar el tick */

    /* Detener por completo el temporizador de físicas y cambiar a STATE_GAMEOVER */
    bl timer_stop
    ldr r0, =current_game_state
    movs r1, #STATE_GAMEOVER
    str r1, [r0, #0]
    bl render_gameover_screen           /* Se dibuja una sola vez */

physics_done:
    pop {r3, r4, r5, r6, r7, pc}

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina auxiliar: lose_one_life
 * Decrementa en 1 el contador de vidas si es mayor a 0 (nunca queda negativo).
 * Parámetros: ninguno | Retorno: ninguno | Destruye: r0, r1.
 * ---------------------------------------------------------------------------- */
.thumb_func
lose_one_life:
    ldr r0, =remaining_lives
    ldr r1, [r0, #0]
    cmp r1, #0
    ble 1f                              /* Ya en 0: no hacer nada */
    subs r1, r1, #1
    str r1, [r0, #0]
1:
    bx lr

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina: render_menu_screen
 * Dibuja la pantalla de título: dos líneas decorativas, el nombre del juego,
 * la nave del jugador al centro y la instrucción "PULSA Z INICIAR".
 * Parámetros: ninguno | Retorno: ninguno.
 * ---------------------------------------------------------------------------- */
.thumb_func
render_menu_screen:
    push {r4, lr}
    bl fb_clear                         /* Borrar framebuffer */

    movs r0, #4
    bl fb_draw_hline                    /* Línea superior en Y = 4 */

    /* Título centrado: 11 caracteres * 8 px = 88 px -> X = (128 - 88) / 2 = 20 */
    movs r0, #20
    movs r1, #14
    ldr r2, =str_title
    bl fb_draw_string

    /* Dibujar nave decorativa en el centro */
    movs r0, #60
    movs r1, #28
    ldr r2, =sprite_player
    bl fb_draw_sprite

    movs r0, #8                         /* 15 caracteres * 8 = 120 px -> X = 4..8 */
    movs r1, #44
    ldr r2, =str_press_z
    bl fb_draw_string

    movs r0, #58
    bl fb_draw_hline                    /* Línea inferior en Y = 58 */

    bl oled_flush                       /* Enviar framebuffer a la OLED */
    pop {r4, pc}

.ltorg

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina: render_game_frame
 * Renderiza un cuadro de la partida: HUD superior, nave, láser y enemigos.
 * Si en este mismo tick se pasó a GAME OVER no dibuja nada, para no tapar la
 * pantalla final que ya dibujó update_game_physics.
 * Parámetros: ninguno | Retorno: ninguno.
 * ---------------------------------------------------------------------------- */
.thumb_func
render_game_frame:
    push {r4, r5, r6, lr}               /* 4 registros = 16 bytes */

    /* Si acaba de pasar a GAMEOVER en este frame, no sobreescribir pantalla final */
    ldr r0, =current_game_state
    ldr r0, [r0, #0]
    cmp r0, #STATE_PLAYING
    bne render_frame_exit

    bl fb_clear

    /* 1. Dibujar Interfaz HUD: "PTS:xxx   VID:x" */
    movs r0, #0
    movs r1, #0
    ldr r2, =str_hud_pts
    bl fb_draw_string                   /* "PTS:" en X = 0..31 */

    movs r0, #32
    movs r1, #0
    ldr r2, =player_score
    ldr r2, [r2, #0]
    bl fb_draw_num3                     /* Puntuación en 3 cifras (X = 32..55) */

    movs r0, #80
    movs r1, #0
    ldr r2, =str_hud_vid
    bl fb_draw_string                   /* "VID:" en X = 80..111 */

    ldr r2, =remaining_lives
    ldr r2, [r2, #0]
    adds r2, r2, #'0'                   /* Número de vidas (0..3) -> carácter ASCII */
    movs r0, #112
    movs r1, #0
    bl fb_draw_char

    /* Línea divisoria del HUD en Y = 9 */
    movs r0, #9
    bl fb_draw_hline

    /* 2. Dibujar nave del jugador */
    ldr r0, =player_position_x
    ldr r0, [r0, #0]
    ldr r1, =player_position_y
    ldr r1, [r1, #0]
    ldr r2, =sprite_player
    bl fb_draw_sprite

    /* 3. Dibujar proyectil láser (4 píxeles horizontales) si está activo */
    ldr r0, =laser_in_flight
    ldr r0, [r0, #0]
    cmp r0, #0
    beq draw_enemies

    ldr r4, =laser_position_x
    ldr r4, [r4, #0]                    /* r4 = X inicial del láser */
    ldr r5, =laser_position_y
    ldr r5, [r5, #0]                    /* r5 = Y del láser */
    movs r6, #0                         /* r6 = contador de píxel (0..3) */
laser_draw_loop:
    adds r0, r4, r6                     /* X = laser_x + k */
    movs r1, r5
    bl fb_draw_pixel
    adds r6, r6, #1
    cmp r6, #4
    blt laser_draw_loop

    /* 4. Dibujar los 3 enemigos */
draw_enemies:
    movs r4, #0                         /* i = 0..2 */
enemy_draw_loop:
    lsls r5, r4, #2                     /* r5 = i * 4 (offset en el arreglo) */
    ldr r0, =enemy_positions_x
    ldr r0, [r0, r5]
    ldr r1, =enemy_positions_y
    ldr r1, [r1, r5]
    ldr r2, =sprite_enemy
    bl fb_draw_sprite                   /* Los píxeles fuera de pantalla se descartan */

    adds r4, r4, #1
    cmp r4, #3
    blt enemy_draw_loop

    /* 5. Volcar Framebuffer completo a la pantalla OLED */
    bl oled_flush

render_frame_exit:
    pop {r4, r5, r6, pc}

.ltorg

/* ----------------------------------------------------------------------------
 * Subrutina: render_gameover_screen
 * Muestra la pantalla de Game Over con el puntaje final alcanzado y la
 * instrucción para volver a jugar.
 * Parámetros: ninguno | Retorno: ninguno.
 * ---------------------------------------------------------------------------- */
.thumb_func
render_gameover_screen:
    push {r4, lr}
    bl fb_clear

    movs r0, #4
    bl fb_draw_hline                    /* Línea decorativa superior */

    movs r0, #28
    movs r1, #12
    ldr r2, =str_gameover
    bl fb_draw_string                   /* "GAME OVER" */

    movs r0, #28
    movs r1, #28
    ldr r2, =str_hud_pts
    bl fb_draw_string                   /* "PTS:" */

    movs r0, #60
    movs r1, #28
    ldr r2, =player_score
    ldr r2, [r2, #0]
    bl fb_draw_num3                     /* Puntuación final */

    movs r0, #8
    movs r1, #46
    ldr r2, =str_press_z
    bl fb_draw_string                   /* "PULSA Z INICIAR" */

    movs r0, #58
    bl fb_draw_hline                    /* Línea decorativa inferior */

    bl oled_flush
    pop {r4, pc}

.ltorg

/* ============================================================================
 * Datos constantes en memoria de solo lectura (.rodata, se quedan en flash)
 * Formato de sprite: 8 bytes, 1 byte por fila (de arriba hacia abajo);
 * el bit 7 es la columna izquierda y el bit 0 la columna derecha.
 * ============================================================================ */
.section .rodata
.align 2

/* Sprite 8x8: Nave Espacial del Jugador (apuntando a la derecha) */
sprite_player:
    .byte 0b11000000                    /* ##......  */
    .byte 0b11110000                    /* ####....  */
    .byte 0b01111100                    /* .#####..  */
    .byte 0b11111111                    /* ########  */
    .byte 0b11111111                    /* ########  */
    .byte 0b01111100                    /* .#####..  */
    .byte 0b11110000                    /* ####....  */
    .byte 0b11000000                    /* ##......  */

/* Sprite 8x8: Invasor / Asteroide Enemigo */
sprite_enemy:
    .byte 0b00111100                    /* ..####..  */
    .byte 0b01111110                    /* .######.  */
    .byte 0b11011011                    /* ##.##.##  */
    .byte 0b11111111                    /* ########  */
    .byte 0b11111111                    /* ########  */
    .byte 0b01011010                    /* .#.##.#.  */
    .byte 0b10000001                    /* #......#  */
    .byte 0b01000010                    /* .#....#.  */

/* Cadenas terminadas en cero (.asciz). La fuente solo tiene A-Z, 0-9,
 * espacio, ':' y '-', por eso todos los textos van en mayúsculas. */
str_title:
    .asciz "ASTRO SPACE"                /* Nombre del juego (11 caracteres) */
str_press_z:
    .asciz "PULSA Z INICIAR"
str_hud_pts:
    .asciz "PTS:"
str_hud_vid:
    .asciz "VID:"
str_gameover:
    .asciz "GAME OVER"
