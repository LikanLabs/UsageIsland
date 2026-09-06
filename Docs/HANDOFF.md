# Memoria de continuidad — Usage Island

Actualizado: 5 de septiembre de 2026. Leer junto con `AGENTS.md` antes de continuar.

## Objetivo y decisiones del usuario

Crear una app nativa macOS para consultar el consumo de Codex, destinada a la comunidad como código abierto bajo LikanLabs. La distribución deseada es GitHub Releases + Homebrew Cask, sin pasar por la Mac App Store.

Antes de publicar, el usuario pidió diferenciar el diseño de la imagen de referencia de otra persona. Autorizó explícitamente cambiar el estilo y permitir indicador a la izquierda, derecha o arriba junto al notch, con ocultación automática opcional como el Dock. Esta autorización visual posterior es una excepción expresa a la prohibición de rediseñar v26 en `AGENTS.md`. Las vistas antiguas v26 permanecen en el repositorio; la app activa usa las vistas CodexEdge.

La última petición autoriza negro unido al borde/notch, aro con porcentaje y contexto de sesión/semana, apertura solo con clic y ajustes dentro del mismo panel. Se implementó y probó con control nativo. Se eliminó el espacio transparente que alejaba el detalle del notch; la separación visible ahora es uniforme.

## Estado implementado

- App nativa Swift 6, macOS 14+, SwiftUI/AppKit, sin nuevas dependencias.
- Codex real mediante CLI instalada y `codex app-server`, reutilizando autenticación sin leer credenciales. No se muestran proveedores demo en producción.
- Uso de sesión y semanal, fechas de reinicio absolutas mostradas en la zona horaria local del Mac. Español, inglés o idioma automático.
- Tamaño 75–150%, posición y ocultación automática persistidos en preferencias.
- Solo clic en la pill abre/cierra el detalle. Engranaje cambia a ajustes en el mismo panel; flecha vuelve al consumo. Clic fuera, Escape o cerrar lo cierran. Menú contextual con actualizar y salir.
- Auto-hide con sondeo de posición del cursor cada 100 ms, espera de 450 ms y animación. Sin permiso de Accesibilidad para detectar cursor. Detalle fijado o menú abierto mantienen visible el indicador.
- Refresco periódico, suspensión/reactivación y recuperación ante fallos del proceso; preserva último dato válido marcado como antiguo.

## Archivos relevantes

- `Sources/UsageIslandPrototype/UI/CodexEdgeView.swift`: diseño nuevo y detalle.
- `UI/AppearanceSettingsView.swift` y `Models/AppPreferences.swift` bajo el mismo directorio de fuentes: preferencias.
- `Window/CodexEdgeWindowController.swift`, `EdgeWindowGeometry.swift`, `DockVisibilityState.swift`: ventanas, posiciones y ocultación.
- `App/UsageIslandApp.swift`, `Models/AppModel.swift`, `Store/` y `Providers/Codex/`: composición y datos.
- `Tests/UsageIslandPrototypeTests/ResilienceScenarios.swift`: escenarios sintéticos compartidos con runner independiente.
- `Scripts/package-app.sh`: empaquetado local; se corrigió expansión de versión en Info.plist. Bundle ID `com.likanlabs.usageisland`, versión local `0.1.0`.
- `README.md`, `Docs/VALIDATION.md`, `.github/workflows/`, `Distribution/homebrew/`, `LICENSE`, `Assets/OpenAI/`: documentación y preparación de distribución. Revisar que VALIDATION refleje los últimos cambios.

## Verificación realizada y límites

- `swift build --product UsageIslandPrototype`: pasa.
- `./Scripts/package-app.sh`: build release, Info.plist y firma ad-hoc verificados.
- `./Scripts/verify-resilience.sh`: pasa recuperación, limpieza sin procesos duplicados, autenticación, sleep/wake, 768 casos de geometría y estados de auto-hide, fijación, menú y modo fijo.
- `git diff --check`: pasa.
- `swift test`: falla por `no such module 'XCTest'`; este entorno tiene Command Line Tools, no Xcode completo. El runner independiente no sustituye la suite completa.
- Render estático del diseño con datos sintéticos inspeccionado, sin recortes visibles. Archivo temporal `/tmp/usage-island-codex-preview.png` (puede desaparecer).
- En trabajo anterior se verificaron consultas reales y recuperación al terminar el proceso hijo dedicado de prueba; no equivale a validar toda la nueva interfaz.
- Persistencia tiene pruebas XCTest ampliadas, pero no ejecutadas por la limitación anterior.
- Dos warnings existentes de casts innecesarios en `UnifiedIslandSurfaceView.swift` permanecen.

## Pruebas en el Mac y siguiente revisión

### Revisión visual más reciente

Última refinación lateral: logo de Codex dentro del aro y porcentaje usado debajo; en notch usa una banda horizontal compacta con logo/aro y porcentaje en línea; color
según restante (>50 verde, >25 amarillo, >10 naranja, <=10 rojo). Abrir con clic
solicita refresco sin duplicar una consulta activa; el sondeo por minuto sigue
incluso con la pill oculta. Hover en el borde solo revela la pill.
Las páginas animan superficie y contenido en 240 ms dentro de un host estable;
Volver tiene texto y una zona de clic mayor. Al cerrar desde ajustes no se resetea
la página hasta ocultar la ventana. `EdgePanelNavigation` protege completados de
cierres antiguos al reabrir rápido. Pruebas de regresión y colores pasan, al igual
que geometría (768) y builds. `swift test` sigue bloqueado por XCTest ausente.
El clic en ajustes se verificó y corrigió para usar event.window; leer la posición
global del cursor clasificaba erróneamente clics de accesibilidad como externos.


La app activa es negra, con pill unida al borde o base del notch. El porcentaje
lleva aro continuo (discontinuo cuando es antiguo) y etiqueta de sesión/semana.
No hay marcas LikanLabs/Usage Island dentro del panel. Los ajustes viven en la misma
ventana flotante, para evitar aparecer detrás de VS Code. No se abre con hover.
Se probaron posiciones, idiomas, 75–150%, vuelta desde ajustes, cierre, lectura real
y persistencia. Los 768 casos sintéticos incluyen distintas alturas, notch/no-notch
y distancia visible uniforme. Ver `VALIDATION.md` para crítica y límites.
La build release final está abierta con derecha/85%/automático/auto-hide apagado.
⌘Tab cerró el panel correctamente. Se añadieron cierres por pérdida de foco y
activación de otra app; los clics dirigidos a VS Code por la herramienta no
reprodujeron de forma fiable ese cambio de foco, por lo que falta verificar el
clic físico fuera del panel. `swift test` sigue fallando por ausencia de XCTest;
build, firma local, runner y `git diff --check` pasan. No se hicieron commits.

### Actualización tras la sesión inicial de pruebas del 5 de septiembre

El control nativo ya funciona. Se abrió la app, se comprobó lectura real y refresco,
ajustes, selección de izquierda/derecha/arriba, tamaños 75–150%, inglés/automático,
activación/desactivación de auto-hide, Escape y salida por menú contextual.
Se corrigió en `CodexUsageProvider.swift` la recuperación tras cancelar una consulta
en curso: JSON-RPC cierra el transporte, y ahora la siguiente actualización lo
reemplaza sin sufrir primero un fallo evitable. La regresión sintética falló antes
del cambio y pasó después; cancelar una consulta en cola conserva el cliente sano.
El runner de resiliencia completo pasa, incluido los 768 casos de geometría.
`swift test` sigue bloqueado por falta de XCTest. Se recompiló y firmó localmente
`dist/Usage Island.app`, se relanzó y volvió a mostrar consumo real. Preferencias
originales restauradas y verificadas tras reiniciar: derecha, 85%, automático,
auto-hide desactivado. No se modificaron vistas ni se crearon commits.
Quedan pruebas físicas de pantallas/suspensión y recorridos continuos del cursor;
ver `VALIDATION.md`. El bloqueo de herramienta descrito a continuación es histórico.

El usuario autorizó controlar su Mac, abrir la app y probar todo. Quedó pendiente porque la herramienta de control nativo falla antes de acceder a cualquier ventana con `Sky Computer Use native pipe startup failed`. Se intentó inventario, acceso directo por ruta y reinicio del kernel de la herramienta; todos fallaron. No se conoce la causa raíz ni hay evidencia de que dependa del modelo. Se sugirió reiniciar Codex y continuar desde otra sesión.

1. Reintentar la herramienta de control nativo. Usar `cua_repl` para acciones de interfaz; no sustituirla por eventos sintéticos u otros mecanismos sin petición específica del usuario.
2. Cerrar la versión anterior y abrir `dist/Usage Island.app`. Había una instancia antigua abierta cuando se reconstruyó el paquete; no asumir que lo visible sea la nueva build.
3. Verificar lectura real de Codex, refresco y mensajes de error/antigüedad.
4. Probar izquierda, derecha y arriba; revisar encaje en notch y posibles conflictos con Dock o barra de menú.
5. Probar tamaño mínimo/máximo, español/inglés/automático, textos y persistencia al relanzar. Restaurar preferencias previas tras pruebas.
6. Probar auto-hide real: entrar/salir con cursor, atravesar al detalle, clic para fijar, menú contextual, Escape y clic fuera, regreso a modo fijo, animaciones y accesibilidad con movimiento reducido.
7. Probar cambios de pantalla/Space y suspensión cuando sea viable. Informar claramente cualquier caso no probado.
8. Corregir problemas encontrados dentro del alcance, verificar y pedir revisión del diseño al usuario antes de publicación.

Para abrir manualmente:

```sh
open "/Users/ignaciocoliqueo/Developer/UsageIsland/dist/Usage Island.app"
```

## Publicación posterior

Plan: `LikanLabs/UsageIsland` para código/releases y `LikanLabs/homebrew-tap` para casks de esta y futuras apps de la organización. Los comandos previstos son `brew tap LikanLabs/tap` y `brew install --cask usage-island`; todavía no son un canal publicado y verificado.

La organización fue encontrada previamente; volver a comprobar remotos y permisos antes de operar. Hay workflow y plantilla de cask, pero faltan revisar publicación, URL y checksum reales. La build local no está notarizada; firma Developer ID/notarización son trabajos separados si se decide distribuir así.

No se crearon commits ni se hizo push. El usuario aplazó subir a Git para resolver primero el diseño. El árbol tiene muchos archivos modificados y sin seguimiento: son trabajo del usuario, conservarlos. No ejecutar reset/checkout destructivos ni publicar sin autorización. `AGENTS.md` ya existía y no fue modificado.
