# Automatización de Cineleaf con IA

Cineleaf puede recibir instrucciones de una IA mediante MCP, un protocolo abierto que permite usar herramientas locales de forma estructurada. La IA no necesita mover el ratón ni adivinar dónde está cada botón: recibe operaciones con nombres, campos y límites claros.

## Qué se puede pedir

Ejemplos de instrucciones útiles:

- “Haz 10 vídeos verticales de 20 segundos, uno por producto, con título y llamada a la acción.”
- “Abre este proyecto, divide el segundo clip en 00:04, mueve la segunda parte a 00:12 y baja su volumen.”
- “Añade estos subtítulos con sus tiempos, revisa el plan y exporta a 1080p.”
- “Prepara 32 variaciones sin escribir nada todavía y enséñame el resumen.”

La IA puede crear proyectos, distribuir automáticamente clips superpuestos en pistas compatibles, añadir vídeo, audio, imágenes y texto, inspeccionar identificadores estables, editar clips existentes, añadir subtítulos o marcadores y exportar MP4. Los proyectos creados por IA se abren normalmente en la interfaz de Cineleaf.

Los subtítulos automáticos de la aplicación siguen funcionando de forma local. Mediante MCP, una IA también puede añadir directamente frases ya transcritas como clips con el rol `subtitle`, tiempos exactos, estilo y posición. La calidad creativa o de la transcripción depende de la IA o del reconocedor que prepare el texto; Cineleaf garantiza la aplicación determinista de las operaciones válidas, no que cualquier modelo tome siempre una decisión creativa perfecta.

## Instalación sencilla

Necesitas Node.js 20 o posterior porque el servidor MCP usa el SDK oficial de TypeScript. Esto es opcional: el editor normal no necesita Node.js.

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\Cineleaf\Automation\setup_cineleaf_mcp.ps1" -AllowedRoot "D:\Videos"
```

Mac:

```bash
"/Applications/Cineleaf.app/Contents/Resources/Automation/setup_cineleaf_mcp.sh" "$HOME/Movies"
```

Cambia la última ruta por la carpeta que contiene tus vídeos y proyectos. El script copia el servidor a los datos locales del usuario, instala dependencias bloqueadas por versión y genera `cineleaf-mcp-config.json`. No modifica automáticamente la configuración de ninguna IA: abre ese archivo y copia la entrada `cineleaf` en la sección de servidores MCP de tu cliente.

Para autorizar varias carpetas, un usuario avanzado puede añadir pares `--root` y ruta a `args`. También se admite la variable `CINELEAF_AUTOMATION_CLI` para probar un puente nativo situado en otra ubicación.

## Flujo seguro recomendado

1. La IA llama a `cineleaf_capabilities` para conocer límites y carpetas permitidas.
2. Inspecciona el proyecto antes de editarlo; nunca inventa un identificador de clip.
3. Ejecuta la creación o edición con `dryRun=true` y muestra el resumen.
4. Solo después de la aprobación repite la misma operación con `dryRun=false`, `confirmWrite=true` y una `idempotencyKey` única.
5. Comprueba el resultado devuelto por el motor nativo antes de afirmar que terminó.

Una clave de reintento solo puede corresponder a una solicitud concreta. Repetirla devuelve el resultado anterior; reutilizarla con datos diferentes produce un error. Si el codificador se interrumpe después de guardar el proyecto, el mismo trabajo puede reanudar la exportación.

## Herramientas disponibles

| Herramienta | Uso |
| --- | --- |
| `cineleaf_capabilities` | Lee el contrato, límites y carpetas autorizadas. |
| `cineleaf_create_video` | Planifica, crea y opcionalmente exporta un vídeo. |
| `cineleaf_create_video_batch` | Procesa hasta 32 vídeos y conserva el orden de resultados. |
| `cineleaf_inspect_project` | Devuelve clips, recursos y marcadores con identificadores estables. |
| `cineleaf_edit_project` | Mueve, recorta, transforma, divide, silencia o borra clips; añade texto, subtítulos y marcadores. |

Cada vídeo admite hasta 500 entradas multimedia y 500 textos. Un lote admite 32 vídeos y una concurrencia entre 1 y 4. El valor predeterminado es 2 porque normalmente ofrece mejor rendimiento total que saturar al mismo tiempo el decodificador, la GPU y el disco.

## Ejemplo conceptual de un vídeo vertical

La IA enviaría una solicitud equivalente a esta primero como simulación:

```json
{
  "projectPath": "D:\\Videos\\salida\\anuncio.cineleaf",
  "outputPath": "D:\\Videos\\salida\\anuncio.mp4",
  "name": "Anuncio vertical",
  "canvasPreset": "vertical9x16",
  "media": [
    {
      "path": "D:\\Videos\\originales\\producto.mp4",
      "sourceStartSeconds": 2,
      "durationSeconds": 8
    }
  ],
  "texts": [
    {
      "role": "subtitle",
      "text": "Una edición rápida y privada",
      "startSeconds": 1,
      "durationSeconds": 3,
      "positionY": 650,
      "backgroundHex": "#000000AA"
    }
  ],
  "export": {
    "resolution": "p1080",
    "codec": "h264",
    "quality": "balanced"
  },
  "dryRun": true
}
```

Tras aprobar el resumen, la IA añade `confirmWrite: true`, `dryRun: false` y una clave única como `anuncio-2026-07-27-01`.

## Privacidad y protección

- El servidor usa transporte local por entrada/salida estándar; no abre un puerto ni incluye telemetría.
- Las rutas se normalizan, se resuelven enlaces simbólicos y uniones de directorio, y deben quedar realmente dentro de una carpeta autorizada.
- Los procesos nativos se inician sin intérprete de comandos, para que las rutas sean datos y no órdenes de shell.
- La salida de protocolo tiene un límite de tamaño y los diagnósticos se separan del canal MCP.
- Los guardados usan archivos temporales, validación nativa, renombrado atómico y restauración si falla una sustitución.
- Las ediciones simultáneas del mismo proyecto se serializan dentro de una misma instancia del servidor MCP para no perder cambios; una salida existente nunca se reemplaza sin `overwrite=true`. No ejecutes dos servidores MCP distintos sobre el mismo proyecto al mismo tiempo.
- Los cachés tienen límites y se invalidan cuando cambia el tamaño o la fecha del archivo.

El servidor MCP no llama por sí solo a ninguna API de modelos. La privacidad final también depende del cliente de IA elegido y de si ese cliente envía el texto, los nombres de archivo o el contenido multimedia a un servicio externo.

## Rendimiento

La planificación deduplica inspecciones del mismo archivo, trabaja con concurrencia limitada, conserva el orden del lote y delega la exportación al motor nativo. Windows prueba primero codificadores de hardware compatibles; Mac usa AVFoundation. La exportación siempre lee los originales, aunque la vista previa utilice derivados más ligeros.

En la medición reproducible de Windows, validar las solicitudes y rutas reales, construir 32 proyectos de 100 clips y crear/eliminar sus paquetes temporales de validación tuvo una mediana de 93,411 ms con Node.js 24.16.0. No incluye validación nativa, lectura real de vídeo ni exportación. Ejecuta `npm run benchmark --prefix Automation/mcp` para repetirla; las medidas completas están en [PERFORMANCE.md](PERFORMANCE.md).
