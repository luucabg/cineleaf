<p align="center">
  <img src="Branding/Exports/cineleaf-logo-horizontal.svg" alt="Cineleaf" width="460">
</p>

<p align="center">
  <strong>Edición de vídeo rápida, privada y gratuita para Windows y Mac.</strong><br>
  Sin cuenta, nube, anuncios, suscripción, marca de agua ni seguimiento.
</p>

<p align="center">
  <a href="https://github.com/luucabg/cineleaf/releases/tag/v0.2.0-beta.1"><img alt="Última versión" src="https://img.shields.io/github/v/release/luucabg/cineleaf?include_prereleases&color=327C60"></a>
  <a href="https://github.com/luucabg/cineleaf/actions/workflows/windows-ci.yml"><img alt="Pruebas de Windows" src="https://github.com/luucabg/cineleaf/actions/workflows/windows-ci.yml/badge.svg"></a>
  <a href="https://github.com/luucabg/cineleaf/actions/workflows/ci.yml"><img alt="Pruebas de Mac" src="https://github.com/luucabg/cineleaf/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="Licencia MIT" src="https://img.shields.io/badge/license-MIT-327C60.svg"></a>
</p>

## Descargar Cineleaf para Windows

La forma más sencilla es descargar **[Cineleaf para Windows (instalador EXE)](https://github.com/luucabg/cineleaf/releases/download/v0.2.0-beta.1/Cineleaf-0.2.0-beta.1-Windows-x64-Setup.exe)**.

1. Descarga el archivo.
2. Ábrelo y sigue el instalador. No necesita permisos de administrador.
3. Abre Cineleaf desde el menú Inicio.

También existe una **[versión portátil ZIP](https://github.com/luucabg/cineleaf/releases/download/v0.2.0-beta.1/Cineleaf-0.2.0-beta.1-Windows-x64-Portable.zip)** que no se instala. Los usuarios avanzados pueden comprobar la descarga con el archivo de **[sumas SHA-256](https://github.com/luucabg/cineleaf/releases/download/v0.2.0-beta.1/Cineleaf-0.2.0-beta.1-Windows-SHA256SUMS.txt)**.

> La versión de Windows es una beta para Windows 10/11 de 64 bits. El instalador no está firmado todavía, por lo que Windows puede mostrar una advertencia de SmartScreen. El código, las pruebas y el proceso de construcción son públicos.

## Qué es Cineleaf

Cineleaf es un editor para crear vídeos sin aprender una herramienta profesional complicada. Arrastra vídeos, fotos y música; corta y ordena; añade texto, efectos, transiciones o subtítulos; y exporta un MP4 listo para compartir.

Todo se procesa en tu ordenador. Cineleaf no sube tus vídeos a ningún servidor.

La interfaz está disponible en español e inglés. Los proyectos `.cineleaf` usan el mismo formato en Windows y Mac, así que se pueden mover entre ambos sistemas si las rutas de los archivos multimedia siguen siendo accesibles.

## Súper optimizado para ser rápido

Cineleaf está diseñado para responder al instante incluso en proyectos grandes:

- La línea de tiempo dibuja solo lo que se ve, en vez de crear miles de elementos ocultos.
- Busca los clips visibles con un índice rápido y no recorre el proyecto entero.
- Miniaturas, formas de onda, análisis, subtítulos y exportación trabajan en segundo plano.
- Cancela trabajos de previsualización antiguos cuando haces un cambio nuevo.
- Reutiliza resultados en una caché limitada a 2 GB, evitando repetir trabajo sin llenar el disco.
- Procesa audio y vídeo por partes para mantener limitado el uso de memoria.
- Usa tiempo racional exacto para evitar que los cortes se desplacen por errores decimales.
- Prueba el hardware disponible y prefiere aceleración NVIDIA, Intel, AMD o Windows cuando funciona; si no, usa una alternativa compatible.
- El instalador incluye todo lo necesario: no obliga a instalar .NET ni FFmpeg por separado.

En un Ryzen 5 5600X, localizar lo visible dentro de 10.000 clips tuvo una mediana de **0,0079 ms**; validar un proyecto de una hora con 100 clips, **0,2289 ms**; y mover un clip con copia segura, historial y validación completa, **9,9172 ms**. Son medidas del motor, no una promesa de que toda exportación tarde lo mismo. Consulta [las medidas y sus límites](Documentation/PERFORMANCE.md).

## Controlarlo con una IA

Cineleaf incluye un servidor **MCP**, un puente estándar para que una IA compatible pueda trabajar con el editor sin tener que buscar botones en la pantalla. Puedes pedir, por ejemplo: “crea 12 vídeos verticales con estos clips, añade el título y expórtalos”. La IA puede:

- Examinar un proyecto y recibir identificadores claros de clips, pistas y recursos.
- Preparar uno o hasta 32 vídeos por lote, manteniendo el orden de los resultados.
- Mover, recortar, dividir, transformar, silenciar o borrar clips con tiempos exactos.
- Añadir textos, subtítulos y marcadores, y exportar en H.264 o HEVC de 720p a 4K.
- Ver primero un plan sin tocar archivos y ejecutar después exactamente ese plan.

Todo sigue ocurriendo en tu ordenador. El puente solo puede acceder a las carpetas que tú autorices, no usa una nube de Cineleaf y valida cada proyecto con el motor nativo de Windows o Mac antes de guardarlo. Los trabajos usan claves de reintento: si una exportación se interrumpe, se puede continuar sin crear el proyecto dos veces.

La instalación para IA es opcional y requiere Node.js 20 o posterior. En Windows, después de instalar Cineleaf, abre PowerShell y ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\Cineleaf\Automation\setup_cineleaf_mcp.ps1" -AllowedRoot "D:\Videos"
```

En Mac, después de copiar Cineleaf a Aplicaciones:

```bash
"/Applications/Cineleaf.app/Contents/Resources/Automation/setup_cineleaf_mcp.sh" "$HOME/Movies"
```

El instalador genera un pequeño bloque de configuración para pegar en cualquier cliente compatible con MCP. Consulta la [guía de automatización para IA](Documentation/AI_AUTOMATION.md), con ejemplos y límites explicados sin jerga.

## Funciones disponibles

### Edición cómoda

- Proyectos horizontales, verticales, cuadrados y 4:5; 24, 25, 30, 50 o 60 fps.
- Importación de vídeo, audio e imágenes mediante botón, doble clic o arrastrar y soltar.
- Varias pistas, mover, recortar, dividir, duplicar, borrar, borrado con cierre de hueco, deshacer y rehacer.
- Marcadores, detección local de ritmos y revisión/eliminación de silencios.
- Zoom y desplazamiento fluidos en una línea de tiempo virtualizada.
- Vista previa compuesta en segundo plano con caché y cancelación.

### Efectos y creación

- Posición, escala, rotación, recorte, opacidad, velocidad y reproducción inversa.
- Exposición, contraste, saturación, temperatura, tinte, luces, sombras, nitidez y viñeta.
- Desenfoque, nitidez, monocromo, sepia, bloom y viñeta.
- Fundidos y transiciones de disolución, negro, deslizamiento, barrido y desenfoque.
- Texto configurable y subtítulos sobre el vídeo.
- Exportación MP4 H.264 o HEVC desde 720p hasta 4K, con audio AAC, progreso y cancelación.

### Subtítulos automáticos y privacidad

En Windows, Cineleaf puede transcribir el audio usando el reconocimiento instalado en el propio sistema. No envía el audio a la nube. También importa y exporta SRT y WebVTT. La disponibilidad y los idiomas dependen de los paquetes de voz instalados en Windows; siempre se puede corregir el texto antes de exportar.

### Ideas innovadoras ya incorporadas

- Un proyecto puede abrirse tanto en Windows como en Mac.
- La detección de ritmo crea puntos útiles para cortar al compás.
- La detección de silencio propone cambios para revisar antes de borrar nada.
- La elección automática de codificador prueba la GPU en vez de asumir que funcionará.
- Guardado atómico, autoguardado y recuperación reducen el riesgo de perder trabajo.
- La exportación comprueba espacio libre, limpia archivos incompletos y vuelve a inspeccionar el vídeo final.

## Atajos principales

| Acción | Windows | Mac |
| --- | --- | --- |
| Guardar | Ctrl+S | ⌘S |
| Deshacer / rehacer | Ctrl+Z / Ctrl+Y | ⌘Z / ⇧⌘Z |
| Dividir en el cursor | Ctrl+B | ⌘B |
| Borrar | Supr | Supr |
| Duplicar | Ctrl+D | ⌘D |
| Marcador | M | M |
| Reproducir / pausar | Espacio | Espacio |

## Estado de calidad

Windows pasa 33 pruebas unitarias, 21 pruebas del contrato MCP, 2 pruebas de integración con FFmpeg real y una exportación sintética que se vuelve a inspeccionar. También se verifica cancelación, idiomas, construcción Release sin avisos, instalación silenciosa, arranque y desinstalación. Mac mantiene sus pruebas automatizadas, suma una prueba del puente nativo de IA y verifica una exportación sintética en GitHub Actions.

No es honesto prometer que ningún programa tiene cero bugs. En esta beta no quedan fallos bloqueantes conocidos después de esas comprobaciones. La revisión visual por píxeles de Windows quedó pendiente porque la sesión de escritorio usada para construirlo estaba bloqueada; el proceso sí arrancó y permaneció estable. En Mac sigue pendiente una prueba manual completa en hardware físico. Consulta [STATUS.md](STATUS.md).

## Para desarrolladores

Windows usa .NET 8, WPF y FFmpeg; Mac usa Swift, SwiftUI/AppKit y AVFoundation. No hay dependencia web ni telemetría.

```powershell
git clone https://github.com/luucabg/cineleaf.git
cd cineleaf
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_release.ps1
```

En Mac:

```bash
brew install xcodegen
xcodegen generate
./scripts/build_release.sh
```

La arquitectura, formato de proyecto y pipeline están documentados en [Documentation](Documentation). Las contribuciones son bienvenidas; consulta [CONTRIBUTING.md](CONTRIBUTING.md).

## Licencia

Cineleaf se publica con licencia [MIT](LICENSE). FFmpeg y las demás piezas redistribuidas conservan sus propias licencias, enumeradas en [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
