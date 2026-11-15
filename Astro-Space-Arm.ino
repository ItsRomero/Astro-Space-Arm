/* ============================================================================
 * Proyecto : ASTRO SPACE - Videojuego de naves para RP2040 (Raspberry Pi Pico)
 * Autor    : Oliver Romero
 * Archivo  : Astro-Space-Arm.ino
 * ----------------------------------------------------------------------------
 * Archivo mínimo de arranque: el núcleo Arduino para RP2040 inicializa el
 * microcontrolador (relojes, memoria, .bss/.data) y llama a setup(). Desde
 * ahí se cede el control a game_main(), escrita en ensamblador ARM (main.S),
 * que nunca regresa. Los archivos .S de esta carpeta se compilan y enlazan
 * automáticamente junto con este sketch.
 * ============================================================================ */

/* extern "C" evita que C++ cambie el nombre del símbolo (name mangling),
 * para que el enlazador encuentre la etiqueta "game_main" definida en main.S. */
extern "C" {
  void game_main(void);
}

void setup() {
  game_main();   // Bucle infinito del juego (máquina de estados en main.S)
}

void loop() {
  // No se usa: game_main() nunca retorna.
}
