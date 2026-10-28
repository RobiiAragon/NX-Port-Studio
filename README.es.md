<p align="center">
  <img src="docs/images/hero.svg" alt="NX Port Studio — Tus juegos de Switch, en apps nativas para Apple" width="100%">
</p>

<p align="center">
  <a href="#primeros-pasos">Primeros pasos</a> · <a href="#qué-está-verificado">Estado verificado</a> · <a href="ROADMAP.md">Hoja de ruta</a> · <a href="CONTRIBUTING.md">Colaborar</a> · <a href="CREDITS.md">Créditos</a> · <a href="README.md">English</a>
</p>

**NX Port Studio es un espacio de trabajo para macOS que convierte tus propios archivos de juegos de Nintendo Switch en apps nativas para Apple.** Selecciona un juego, prepara las herramientas y recursos, y crea una app de Mac o un port de iPhone/iPad firmado mediante Xcode.

Es un proyecto independiente basado en [seedds/nxnative](https://github.com/seedds/nxnative). Se conservan el reconocimiento al motor original, sus autores y el aviso MIT. Consulta los [créditos](CREDITS.md) y la [licencia](LICENSE).

## Del archivo a la app

- **Progreso real:** una carpeta por juego con su base, actualizaciones y DLC; etapas y errores del motor visibles.
- **Exportación iOS firmada:** todos los IPA pasan por la firma de Xcode y la verificación del perfil. La instalación es opcional después de exportar correctamente.
- **Recursos originales:** importa datos de tu propio firmware para modelos Mii, fuentes y certificados, con comprobación de versión y contenido.
- **Controles nativos:** configuración por juego, movimiento y vibración cuando el sistema y el hardware conectado los exponen.
- **Redes con alcance claro:** LAN, puente LDN e integración Nextendo son rutas distintas, con pruebas propias.

El motor ejecuta código ARM64 reescrito del juego en Apple silicon e implementa servicios y traducción gráfica. La compatibilidad depende del juego, actualización, perfil y dispositivo exactos. Crear una app no demuestra por sí solo que el juego sea jugable.

## Más allá de la interfaz de compilación

El proyecto también amplía el runtime y las rutas de integración:

- [Sockets Horizon](dm/host/hle_net_backend.c): traducción de direcciones/errores/flags, TCP/UDP reales y cierre/reutilización de descriptores seguros.
- [Entrada HLE bloqueante](dm/host/entry.S): publicación de registros del juego, pilas nativas y esperas que respetan pausa/reanudación.
- [TLS de Apple](dm/host/hle_ssl_apple.m): verificación de certificados/hostname y confianza por contexto; el [importador de firmware](dm/tools/nx_extract/FirmwareResources.cs) aporta CertStore original.
- [Puente LDN original](dm/host/hle_ldn.c): descubrimiento, sesiones, participantes y sincronización reales; falta la comprobación física.
- [Puente nativo de cuenta](dm/host/hle_nextendo_apple.m) y [rutas del servicio](dm/host/hle_nextendo_routes.c): manejo explícito de credenciales/identidad; OAuth limitado no se convierte en una credencial de juego.
- [Mapeo de controles](dm/host/controls_map.h) y [ruta Joy-Con de Mac](dm/host/joycon_mac.inc): layouts Nintendo/Xbox, API públicas de Apple y acceso raw calibrado en Mac. En iOS se respetan las capacidades expuestas por sus API públicas.

Cada mecanismo tiene pruebas y alcances distintos. Esto no demuestra que todos los juegos puedan jugar online.

## Qué está verificado

| Área | Evidencia actual | Alcance |
| --- | --- | --- |
| Studio en macOS | Pasan las pruebas de compilación, configuración, procesos, recursos y firma Xcode. | Apple silicon; Studio requiere macOS 14+. Algunos juegos necesitan funciones más recientes de macOS/Metal. |
| LAN Mac ↔ Switch | Un build anterior probado **completó una carrera de Mario Kart 8 Deluxe 3.0.5** con una Switch física. | Es una referencia histórica con versiones coincidentes y modo LAN. El candidato actual no ha repetido esa carrera. |
| Puente LDN | Implementación C original compatible con `ldn_mitm`, probada con protocolo, datos malformados, participantes y dos procesos. | Falta comprobar la interoperabilidad con una Switch física. Es una ruta diferente de la LAN IP del juego. |
| Nextendo | Están verificados OAuth con aplicación propia, la obtención de NEX ligada a identidad, su lectura desde el Llavero y el catálogo firmado. | OAuth limitado y la credencial NEX son estados distintos. **No se ha validado una partida NEX online nativa.** |
| iPhone/iPad | Está implementada la infraestructura de exportación firmada e instalación. La integración actual de ports y redes sigue en curso. | Este README no afirma un resultado multijugador en iPhone. Siguen aplicando restricciones de dispositivo, firma y plataforma. |
| Android/Windows | Planeados después de estabilizar la base Apple. | Aún no hay builds ni compatibilidad anunciada; ARM y x86 requieren trabajo propio. |

## Primeros pasos

### Requisitos

- Mac con Apple silicon y macOS 14 o posterior para Studio; Xcode con Swift 6. El motor o un juego concreto pueden necesitar herramientas gráficas más recientes.
- Tus archivos de juegos y claves de consola. Las actualizaciones y DLC correspondientes van en la carpeta del mismo juego.
- Para iPhone/iPad: dispositivo físico apto, cuenta/equipo de desarrollo configurados en Xcode, emparejamiento, confianza y modo de desarrollador. Los objetivos actuales del motor utilizan iOS/iPadOS 26 y hardware A17 Pro/M-series compatible; revisa las notas del juego.

### Compilar Studio

Desde un checkout con el código de Studio y del motor:

```sh
cd macOS/NXPortStudio
swift test
swift run NXPortStudio
```

Crear un paquete local:

```sh
./scripts/package_app.sh "/ruta/NX Port Studio.app"
```

El script no sobrescribe un destino existente. Su firma ad-hoc predeterminada corresponde a la **app de Studio para Mac**; una distribución pública notarizada es otro paso. Los **IPA de juegos se firman con Xcode**, sujetos a las reglas de cuenta, dispositivo y vencimiento de Apple.

### Crear un port

1. Abre **Entorno** y prepara las herramientas que el motor indique como necesarias.
2. En **Nuevo port**, selecciona la carpeta del juego y tu `prod.keys`.
3. Opcionalmente importa tus recursos originales en **Firmware** y selecciona el catálogo para nuevos ports.
4. Elige **Mac** o **iPhone/iPad**. En iOS, selecciona un dispositivo apto emparejado e introduce tu Team ID de Xcode.
5. Crea el port. En iOS, la operación sólo termina correctamente después de firmar y verificar el IPA. **Instalar al terminar** controla la instalación, no la firma.

La interfaz actual está en español; la salida técnica mantiene su idioma original. Los productos de compilación y datos extraídos permanecen junto al juego seleccionado. Las exportaciones se guardan en Descargas de forma predeterminada.

## Cada modo de red tiene requisitos distintos

**LAN:** utiliza el modo LAN propio del juego y sockets IP reales. Requiere versiones coincidentes y la misma red. La carrera del build anterior es la referencia física; no certifica un candidato posterior del runtime.

**LDN:** transporta por IP el descubrimiento y los participantes del servicio inalámbrico local. Requiere un peer/módulo compatible y un juego coincidente. Las pruebas entre procesos no sustituyen una comprobación física.

**Nextendo:** integra autorización de cuenta y políticas firmadas del servicio. Studio utiliza el ID de tu aplicación registrada y guarda las credenciales en el Llavero de esta Mac. OAuth con permisos de cuenta no se convierte automáticamente en una credencial NEX de juego. Una solicitud explícita puede obtener una credencial NEX verificada contra la identidad; ese paso de cuenta ya fue comprobado. Un servidor habilitado, una versión aceptada y una credencial guardada describen requisitos distintos; ninguno demuestra una partida online nativa. Consulta la política vigente en el catálogo firmado de la app.

En iOS, el runtime implementa el descubrimiento unicast automático en una subred IPv4 local apta y acotada cuando no dispone de broadcast/multicast. La dirección de peer avanzada es opcional. Falta validar este descubrimiento automático en un iPhone físico.

Para las salas creadas en el iPhone/iPad, **Juego local → Activar puente** habilita un [puente de descubrimiento local](dm/net/lan_relay.c) opcional en el Mac. Mantén Studio abierto en la misma red. El puente retransmite el descubrimiento LAN/LDN compatible; la partida conecta directamente a los participantes. Se inicia apagado, muestra tráfico y errores reales, y no requiere cuenta ni introducir una IP. **La interoperabilidad física de salas alojadas en el iPhone sigue pendiente.**

### Bloqueos actuales de servicios de juego

Las rutas nativas Nextendo probadas siguen bloqueadas por certificados: cinco certificados de servidor con diez años de validez fallan la política nativa de Apple, y el endpoint de autenticación configurado para Mario Kart carece de un certificado validado para su hostname. La verificación sigue activa. El build disponible de Mario Kart 8 Deluxe **3.0.5** también queda fuera del requisito actual **4.0.1** del catálogo firmado. Estos bloqueos son independientes del paso de credenciales de cuenta que sí funcionó. La comprobación corresponde al 2026-10-28; actualiza el catálogo para consultar la política vigente.

## Contenido del repositorio

Aquí van código, arte original del proyecto, perfiles, herramientas, documentación y licencias de dependencias. No van juegos, datos de juego descifrados, claves, archivos de firmware, credenciales ni partidas personales. No se publican capturas, portadas, arte, iconos de juegos ni archivos originales del SDK de Nintendo. Los resultados de validación se describen en texto.

Consulta [Contributing](CONTRIBUTING.md) y la [hoja de ruta](ROADMAP.md). Este proyecto no está afiliado con Nintendo, Apple, Nextendo ni los autores del motor original; utilizar un motor o servicio no implica su respaldo.
