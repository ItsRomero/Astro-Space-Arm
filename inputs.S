/* ============================================================================
 * Proyecto : ASTRO SPACE - Videojuego de naves para RP2040 (Raspberry Pi Pico)
 * Archivo  : inputs.S
 * ----------------------------------------------------------------------------
 * Descripción:
 *   Lectura de los controles por acceso directo a registros (sin SDK):
 *     - Joystick analógico: eje X en GP26 (ADC0) y eje Y en GP27 (ADC1).
 *     - Botón Z del joystick en GP22, entrada digital con pull-up interno
 *       (activo en bajo: 1 = suelto, 0 = presionado).
 *
 * Funciones públicas:
 *   inputs_init        -> configura reloj, resets, pads y ADC.
 *   read_adc_x         -> r0 = desplazamiento X (-2..+2)
 *   read_adc_y         -> r0 = desplazamiento Y (-2..+2)
 *   read_btn_z_pressed -> r0 = 1 solo en el instante en que se pulsa Z.
 *
 * Estándar: AAPCS (r0-r3 de trabajo, r4-r7 y lr preservados, pila a 8 bytes)
 * ============================================================================ */

.syntax unified
.cpu cortex-m0plus
.thumb

/* --- Direcciones Base y Registros MMIO (ver datasheet del RP2040) --- */
.equ CLK_ADC_CTRL,      0x40008060      /* CLOCKS: control de reloj del ADC (Bit 11 = ENABLE) */
.equ RESETS_RESET_CLR,  0x4000F000      /* Alias atómico "clear" de RESETS_RESET (0x4000C000 + 0x3000):
                                           escribir 1 en un bit saca ese periférico de reset */
.equ RESETS_DONE,       0x4000C008      /* Bit = 1 cuando el periférico ya salió de reset */

.equ IO_GPIO22_CTRL,    0x400140B4      /* IO_BANK0: Control de GP22 (0x40014000 + 22*8 + 4) */
.equ PAD_GPIO22,        0x4001C05C      /* PADS_BANK0: Pad de GP22 (0x4001C000 + 4 + 22*4) */
.equ PAD_GPIO26,        0x4001C06C      /* PADS_BANK0: Pad de GP26 (ADC0) */
.equ PAD_GPIO27,        0x4001C070      /* PADS_BANK0: Pad de GP27 (ADC1) */

.equ SIO_GPIO_IN,       0xD0000004      /* SIO: nivel lógico actual de todos los GPIO */
.equ SIO_GPIO_OE_CLR,   0xD0000028      /* SIO: limpiar Output Enable (configurar como entrada) */

.equ ADC_BASE,          0x4004C000      /* Base del periférico ADC */
.equ ADC_CS,            0x00            /* Control and Status: EN, START_ONCE, READY, AINSEL */
.equ ADC_RESULT,        0x04            /* Resultado de conversión de 12 bits (0..4095) */

/* --- Estado previo del botón para detección de flanco --- */
.section .bss
.align 2
previous_button_z_state:
    .space 4                            /* Guarda el estado anterior de GP22 (1 = suelto) */

.section .text
.align 2

.global inputs_init
.global read_adc_x
.global read_adc_y
.global read_btn_z_pressed

/* ----------------------------------------------------------------------------
 * Subrutina: inputs_init
 * Habilita el reloj del ADC, saca de reset ADC/IO_BANK0/PADS_BANK0 y configura
 * GP22 como entrada digital con pull-up y GP26/GP27 como entradas analógicas.
 * Parámetros: ninguno | Retorno: ninguno.
 * ---------------------------------------------------------------------------- */
.thumb_func
inputs_init:
    push {r4, lr}

    /* 1. Habilitar reloj del ADC (Bit 11 en CLK_ADC_CTRL), lectura-modificación-escritura */
    ldr r0, =CLK_ADC_CTRL
    ldr r1, [r0, #0]
    movs r2, #1
    lsls r2, r2, #11                    /* r2 = 1 << 11 */
    orrs r1, r2
    str r1, [r0, #0]

    /* 2. Sacar de reset: ADC (bit 0), IO_BANK0 (bit 5) y PADS_BANK0 (bit 8) */
    ldr r0, =RESETS_RESET_CLR
    ldr r1, =0x00000121                 /* (1<<8) | (1<<5) | (1<<0) */
    str r1, [r0, #0]
    ldr r0, =RESETS_DONE
1:
    ldr r2, [r0, #0]
    ands r2, r1
    cmp r2, r1                          /* ¿Los tres bits ya están en 1? */
    bne 1b                              /* No: seguir esperando */

    /* 3. Configurar GP22 (Botón Z) como función SIO (5) y entrada con Pull-Up */
    ldr r0, =IO_GPIO22_CTRL
    movs r1, #5                         /* FUNCSEL 5 = SIO (GPIO controlado por software) */
    str r1, [r0, #0]

    ldr r0, =PAD_GPIO22
    movs r1, #0x4A                      /* IE (bit 6) | PUE (bit 3) | SCHMITT (bit 1) */
    str r1, [r0, #0]

    ldr r0, =SIO_GPIO_OE_CLR
    movs r1, #1
    lsls r1, r1, #22                    /* GP22 como entrada */
    str r1, [r0, #0]

    /* 4. Configurar Pads de GP26 y GP27 para entrada analógica pura */
    ldr r0, =PAD_GPIO26
    movs r1, #0x80                      /* OD=1 (Output Disable), IE=0 (Input Disable), sin pulls */
    str r1, [r0, #0]
    ldr r0, =PAD_GPIO27
    str r1, [r0, #0]                    /* Mismo valor para GP27 */

    /* 5. Encender el periférico ADC (Bit 0 EN = 1 en ADC_CS) */
    ldr r0, =ADC_BASE
    movs r1, #1
    str r1, [r0, #ADC_CS]

    /* 6. Inicializar estado previo del botón en 1 (no presionado, activo en bajo) */
    ldr r0, =previous_button_z_state
    movs r1, #1
    str r1, [r0, #0]

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: read_adc_x
 * Lee el canal 0 del ADC (GP26) y devuelve un desplazamiento en píxeles.
 * Conversión única (single-shot) con espera activa hasta READY (~2 us).
 * Parámetros: ninguno
 * Retorno   : r0 = delta X (-2, -1, 0, +1, +2)
 * ---------------------------------------------------------------------------- */
.thumb_func
read_adc_x:
    push {r4, lr}

    ldr r0, =ADC_BASE
    /* Seleccionar AINSEL = 0 (GP26), START_ONCE (bit 2) y EN (bit 0) -> 0x0005 */
    movs r1, #5
    str r1, [r0, #ADC_CS]

    /* Esperar a que el bit READY (bit 8 = 0x100) sea 1 */
    movs r2, #1
    lsls r2, r2, #8
1:
    ldr r1, [r0, #ADC_CS]
    ands r1, r2
    beq 1b

    /* Leer valor de 12 bits (0..4095, centro ~2048) */
    ldr r1, [r0, #ADC_RESULT]
    bl adc_to_delta                     /* Convierte r1 en velocidad (-2..+2) en r0 */

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina: read_adc_y
 * Lee el canal 1 del ADC (GP27) y devuelve un desplazamiento en píxeles.
 * Parámetros: ninguno
 * Retorno   : r0 = delta Y (-2, -1, 0, +1, +2)
 * ---------------------------------------------------------------------------- */
.thumb_func
read_adc_y:
    push {r4, lr}

    ldr r0, =ADC_BASE
    /* Seleccionar AINSEL = 1 (bits 12..14 -> 0x1000), START_ONCE (bit 2), EN (bit 0) -> 0x1005 */
    ldr r1, =0x00001005
    str r1, [r0, #ADC_CS]

    /* Esperar a que el bit READY (bit 8 = 0x100) sea 1 */
    movs r2, #1
    lsls r2, r2, #8
1:
    ldr r1, [r0, #ADC_CS]
    ands r1, r2
    beq 1b

    /* Leer valor de 12 bits (0..4095) */
    ldr r1, [r0, #ADC_RESULT]
    bl adc_to_delta

    pop {r4, pc}

/* ----------------------------------------------------------------------------
 * Subrutina auxiliar: adc_to_delta
 * Convierte una lectura del ADC en un desplazamiento por tick, con zona
 * muerta central para que el joystick en reposo no mueva la nave:
 *      0 ..  599 -> -2      600 .. 1499 -> -1      1500 .. 2600 -> 0
 *   2601 .. 3500 -> +1     3501 .. 4095 -> +2
 * Parámetros: r1 = lectura ADC (0..4095)
 * Retorno   : r0 = delta (-2..+2) | Destruye: r2.
 * ---------------------------------------------------------------------------- */
.thumb_func
adc_to_delta:
    ldr r2, =600
    cmp r1, r2
    blt delta_neg2                      /* < 600: inclinación fuerte (-2) */

    ldr r2, =1500
    cmp r1, r2
    blt delta_neg1                      /* < 1500: inclinación suave (-1) */

    ldr r2, =3500
    cmp r1, r2
    bgt delta_pos2                      /* > 3500: inclinación fuerte (+2) */

    ldr r2, =2600
    cmp r1, r2
    bgt delta_pos1                      /* > 2600: inclinación suave (+1) */

    movs r0, #0                         /* Zona muerta central (1500..2600) */
    bx lr

delta_neg2:
    movs r0, #2
    negs r0, r0                         /* r0 = -2 (complemento a dos) */
    bx lr
delta_neg1:
    movs r0, #1
    negs r0, r0                         /* r0 = -1 */
    bx lr
delta_pos1:
    movs r0, #1
    bx lr
delta_pos2:
    movs r0, #2
    bx lr

/* ----------------------------------------------------------------------------
 * Subrutina: read_btn_z_pressed
 * Detecta flanco de bajada en el botón Z del joystick (GP22, activo en bajo).
 * Así una pulsación larga cuenta como una sola pulsación.
 * Nota: no tiene antirrebote por software; como solo se usa para cambiar de
 * pantalla, un rebote no produce efectos visibles.
 * Parámetros: ninguno
 * Retorno   : r0 = 1 si se acaba de pulsar el botón, r0 = 0 en caso contrario.
 * ---------------------------------------------------------------------------- */
.thumb_func
read_btn_z_pressed:
    push {r4, lr}

    ldr r0, =SIO_GPIO_IN
    ldr r1, [r0, #0]                    /* r1 = nivel de los 30 GPIO */
    lsrs r1, r1, #22                    /* Llevar el bit 22 a la posición 0 */
    movs r2, #1
    ands r1, r2                         /* r1 = estado actual de GP22 (0 = presionado, 1 = suelto) */

    ldr r2, =previous_button_z_state
    ldr r3, [r2, #0]                    /* r3 = estado anterior */
    str r1, [r2, #0]                    /* Actualizar estado anterior */

    /* Ocurre flanco de bajada si antes era 1 (suelto) y ahora es 0 (presionado) */
    movs r0, #0
    cmp r3, #1
    bne 1f
    cmp r1, #0
    bne 1f
    movs r0, #1                         /* ¡Botón pulsado! */
1:
    pop {r4, pc}

.ltorg
