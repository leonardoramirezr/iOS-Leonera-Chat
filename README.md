# Leonera Chat

App de iOS, hecha en SwiftUI y sin dependencias externas, con las funciones de
[WillChat](https://github.com/leonardoramirezr/leo-os/tree/main/apps/willchat), adaptadas al estilo de iOS.

## Funciones

- **Chat con OpenAI** a través de la Responses API en modo `background`: la respuesta se consulta cada
  2 s y, si cierras la app a mitad, se retoma al volver a abrirla. Se puede detener y reintentar.
- **Crear y editar imágenes** con la herramienta `image_generation`. Adjunta fotos desde la fototeca,
  la cámara o el portapapeles; las imágenes generadas se reenvían en los turnos siguientes para seguir
  editándolas. Se ven a pantalla completa (con zoom), se guardan en Fotos y se comparten.
- **Markdown** en las respuestas: títulos, listas, citas, bloques de código, tablas y formato en línea.
- **Dictado** con Whisper (`whisper-large-v3`) en Groq: forma de onda, cronómetro, límite de 3 minutos,
  y el texto queda en el mensaje para revisarlo antes de enviarlo.
- **Mini apps**: prompts que preguntan antes de enviarse. Escribe `[[[pregunta]]]` donde quieras que se
  te pregunte algo y agrega campos de imágenes o archivos (PDF, texto…). Cada una guarda su último
  resultado, que sigue generándose aunque cambies de pantalla.
- **Ajustes**: modelo de texto y de imagen (los que tu key puede usar, o cualquier ID), y las API keys de
  OpenAI y Groq, guardadas en el Llavero del dispositivo y enviadas solo a `api.openai.com` y
  `api.groq.com`.
- En español e inglés, según el idioma del iPhone.

A diferencia de la versión web, todo se guarda en el dispositivo: las keys en el Llavero; la conversación,
las mini apps y sus resultados en archivos de la app.

## Desarrollo

El proyecto de Xcode se genera con [XcodeGen](https://github.com/yonaskolb/XcodeGen) a partir de
`project.yml`:

```sh
brew install xcodegen
xcodegen generate
open LeoneraChat.xcodeproj
```

Requiere Xcode 16 o posterior; la app funciona desde iOS 17. El bundle ID
(`com.leonardoramirezr.leonerachat`) es el build setting `APP_BUNDLE_ID`; si se agregan extensiones,
usan `$(APP_BUNDLE_ID).<sufijo>`.

## Distribución: Ad Hoc en GitHub Pages

Cada push (a cualquier rama salvo `gh-pages`) ejecuta `.github/workflows/build.yml` en `macos-15`:
compila, firma Ad Hoc y publica el IPA en GitHub Pages, desde donde se instala abriendo la página en
Safari en el iPhone.

### Secrets necesarios

En **Settings › Secrets and variables › Actions** del repositorio (secrets del repositorio, no de una
organización):

| Secret | Qué es |
| --- | --- |
| `ASC_KEY_ID` | Key ID de la clave de la API de App Store Connect. |
| `ASC_ISSUER_ID` | Issuer ID de esa clave. |
| `ASC_KEY_P8` | El contenido completo del archivo `.p8`, con las líneas `BEGIN`/`END`. Debe ser una **Team Key con rol Admin** (App Store Connect › Users and Access › Integrations). |
| `APPLE_TEAM_ID` | El Team ID de la cuenta de desarrollador. |

Sin ningún secret, el workflow genera un IPA **sin firmar** (como artefacto de la ejecución, sin release
ni página). Con solo algunos, falla indicando cuáles faltan.

### Activar GitHub Pages

Después del **primer build firmado** (que crea la rama `gh-pages`), activa **Settings › Pages** con
*Source: Deploy from a branch*, rama `gh-pages` y carpeta `/ (root)`. La portada queda en
`https://leonardoramirezr.github.io/iOS-Leonera-Chat/`, con un botón para la última versión estable y la
lista de todos los builds.

### Añadir un iPhone

Basta con registrar su UDID en developer.apple.com › Certificates, IDs & Profiles › Devices y hacer
push: el siguiente build genera el perfil Ad Hoc con todos los dispositivos registrados.

### Qué hace cada build

1. **Etiqueta.** En `main`, `0.x.0`, subiendo el número intermedio respecto a la última etiqueta, y se
   publica como release estable (*Latest*). En otras ramas, `build-<run_number>-<sha7>`, publicada como
   pre-release. Ningún build se cancela: los de `main` van uno tras otro (grupo de concurrencia `main`) y
   los demás cada uno en su grupo (`run_id`).
2. **Validación** con la API de App Store Connect (`scripts/asc.py`, solo biblioteca estándar de Python y
   `openssl` para el JWT ES256): que la clave funcione y que haya al menos un iPhone registrado.
3. **Archive** con firma automática (`-allowProvisioningUpdates` y la clave de la API): Xcode registra el
   App ID y crea los perfiles.
4. **Exportación Ad Hoc** (`method=release-testing`), con el certificado de distribución gestionado en la
   nube y un perfil con todos los dispositivos registrados. Luego se comprueba que cada bundle lleve un
   `embedded.mobileprovision` Ad Hoc y cuántos dispositivos incluye.
5. **Publicación**: release en GitHub con el IPA y, en `gh-pages`, una carpeta por etiqueta con el IPA,
   `manifest.plist`, `index.html` (botón `itms-services://`) y `build.json`. `scripts/publish-pages.sh`
   reescribe la rama como un único commit huérfano (los IPA no se acumulan en el historial), conserva
   todas las versiones de `main` y los últimos 20 builds de ramas, y reintenta si otro build publica a
   la vez. El enlace de instalación aparece en el resumen de la ejecución y en las notas de la release.
6. **Limpieza**: xcodebuild crea en cada ejecución un certificado «Apple Development» temporal; al final
   (aunque el build falle) se revoca por la API, solo el que no estaba en el llavero antes del archive.
