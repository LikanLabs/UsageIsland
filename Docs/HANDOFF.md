# Memoria de continuidad — Usage Island

Actualizado: 26 de septiembre de 2026. Leer junto con `AGENTS.md` antes de continuar.

## Objetivo y decisiones del usuario

App nativa macOS de código abierto (LikanLabs) para consultar el consumo de
Codex. Distribución por GitHub Releases + Homebrew Cask, sin Mac App Store.

- El 5 de septiembre el usuario autorizó sustituir el diseño v26 por la UI negra
  CodexEdge: pill unida al borde o al notch (izquierda, derecha o arriba), aro con
  porcentaje y contexto sesión/semana, apertura solo con clic, ajustes en el mismo
  panel y ocultación automática opcional.
- El 26 de septiembre autorizó eliminar el código v26 que ya no se usaba
  (`IslandWindowController`, `PulseView`, `UnifiedIsland*`, `WingViews`,
  `VisualTokens`, `BeaconController`, `MenuBarOccupancyService`, `Formatting`).
  `AGENTS.md` declara ahora CodexEdge como línea base visual.
- El 26 de septiembre pidió agregar Claude: la pill muestra el proveedor usado
  más recientemente y el panel muestra ambos. Claude se conecta desde Ajustes con
  un puente de barra de estado (sin leer credenciales).
- Firma Developer ID y notarización: opcionales vía secretos de GitHub (ver
  README). Sin secretos, el release se firma ad hoc como hasta ahora.

## Estado implementado

- Swift 6, macOS 14+, SwiftUI/AppKit, sin dependencias externas.
- Claude: cada 5 minutos (con espera creciente si falla, hasta 1 hora) la app
  consulta a la CLI instalada `get_usage`
  (aislada, sin prompt ni tokens); cubre terminal, app de escritorio y claude.ai.
  El 1 de octubre se quitó el puente opcional de barra de estado: Codex y
  Claude se detectan solos y no hay nada que conectar. Al arrancar, la app
  borra la barra que agregaban las versiones 0.1.3–0.1.7.
- Codex real mediante `codex app-server` (JSON-RPC por stdio), reutilizando la
  autenticación de la CLI sin leer credenciales. Sin datos demo en producción.
- Uso de sesión y semanal con fechas de reinicio absolutas; español, inglés o
  automático (fechas en el mismo idioma que el texto).
- Preferencias persistidas: tamaño 75–150 %, posición, idioma, auto-hide y
  porcentaje disponible/consumido.
- Refresco cada minuto, pausa en reposo, recuperación ante fallos del proceso y
  conservación del último dato válido marcado como antiguo. Un dato antiguo cuyo
  reinicio ya pasó se muestra como «—».

- 30 de septiembre: abrir al iniciar sesión (opcional), avisos locales al
  20/10/0 % y al reiniciarse un límite bajo, cuenta regresiva en la pill al
  agotarse, reapertura automática tras `brew upgrade`, pausa con pantalla
  bloqueada o apagada y modo de bajo consumo, barra de Claude tolerante a
  desinstalación.

## Archivos relevantes

Rutas relativas a `Sources/UsageIslandPrototype/`:

- `UI/CodexEdgeView.swift`, `UI/AppearanceSettingsView.swift`, `UI/CodexMark.swift`,
  `UI/ClaudeMark.swift`: interfaz.
- `Infrastructure/Claude/`, `Providers/Claude/`: consulta a la CLI, limpieza
  de la barra antigua y proveedor de Claude.
- `UI/WelcomeView.swift`: bienvenida de la primera vez.
- `Window/CodexEdgeWindowController.swift`, `EdgeWindowGeometry.swift`,
  `DockVisibilityState.swift`, `EdgePanelNavigation.swift`, `ScreenNotchGeometry.swift`:
  ventanas, geometría y auto-hide.
- `App/`, `Models/`, `Store/`, `Providers/Codex/`: composición y datos.
- `Infrastructure/Processes/`, `Infrastructure/JSONRPC/`, `Infrastructure/Codex/`:
  proceso hijo y protocolo.

Scripts y pruebas: `Scripts/package-app.sh`, `Scripts/notarize-app.sh`,
`Scripts/verify-resilience.sh`, `Tests/UsageIslandPrototypeTests/ResilienceScenarios.swift`.

## Verificación

- `swift test` funciona con Xcode completo (ver `Docs/VALIDATION.md` para el último
  resultado). CI y release ejecutan `swift test` y el runner de resiliencia.
- `./Scripts/verify-resilience.sh` usa el sistema de build nativo en toolchains
  que por defecto usan swiftbuild (Swift 6.4+).

## Pendiente

1. Pruebas físicas: suspensión real, conectar/desconectar pantallas, clamshell,
   pantalla completa y recorridos continuos del cursor con auto-hide.
2. Configurar los secretos de firma/notarización si se quiere evitar el aviso de
   Gatekeeper; verificar el primer release notarizado.
3. Actualizar el cask en `LikanLabs/homebrew-tap` con versión y SHA-256 de cada release.

No publicar ni hacer commits sin autorización explícita del usuario.
