# Guia diaria: activar el pod y usarlo con OpenCode en Ubuntu

Esta guia describe el uso de la instalacion que ya existe en este equipo. No
hace falta ejecutar `install.sh` cada vez.

OpenCode se conecta a `http://127.0.0.1:18000/v1`, pero la inferencia se ejecuta
en una GPU de Runpod. Esa direccion local solo funciona mientras
`opencode-gpu` mantiene abierto el tunel SSH hacia el pod.

## Opcion recomendada: una sesion protegida desde la terminal

Este recorrido arranca el pod, abre OpenCode con el agente privado y termina el
pod al salir de OpenCode.

1. Abre una terminal en la carpeta con la que quieras trabajar.
2. Comprueba que no haya una sesion anterior activa:

   ```bash
   opencode-gpu status
   ```

   Si muestra `Status: down`, continua. Si devuelve datos de un pod activo,
   reutilizalo con `opencode --agent private-gpu` o ejecuta `opencode-gpu down`
   antes de crear otro.

3. Consulta la GPU, el centro de datos y el precio que se elegirian:

   ```bash
   opencode-gpu plan
   ```

   `plan` no crea ningun recurso facturable. Antes de continuar, revisa sobre
   todo `clinical_mode`, `price_per_hour`, `gpu`, `data_center`, `engine` y
   `max_session_minutes`. Para trabajos clinicos, `clinical_mode` debe ser
   `true`; si aparece un volumen, su `purpose` debe ser `model-cache-only` y su
   `inference_access`, `read-only`.

4. Inicia la sesion:

   ```bash
   opencode-gpu session
   ```

5. Espera sin cerrar la terminal. El comando hace todo lo siguiente:

   - crea el pod en Runpod;
   - espera a que SSH este disponible;
   - arranca `llama.cpp` o vLLM, segun la GPU seleccionada;
   - abre el tunel local en `127.0.0.1:18000`;
   - espera hasta que el modelo responda;
   - inicia OpenCode con el agente `private-gpu`.

   El arranque puede tardar varios minutos. Con la cache persistente caliente
   suele ser mucho mas rapido, pero no cierres la terminal hasta que aparezca
   OpenCode.

6. Trabaja normalmente en OpenCode. En este modo, el agente ya seleccionado es
   `private-gpu`, que usa `runpod-private/qwen3.8-27b-fp8`. El agente permite
   leer, buscar y editar archivos locales, pero bloquea shell, web, MCP, skills
   y agentes delegados.
7. Cuando termines, sal de OpenCode de forma normal. El comando `session`
   ejecutara automaticamente `opencode-gpu down`.
8. Comprueba que el cierre se haya confirmado:

   ```bash
   opencode-gpu status
   ```

   El resultado esperado es `Status: down`.

Aunque `session` termina el pod al salir, ejecuta manualmente
`opencode-gpu down` si la terminal se cierra de forma anomala o no puedes
confirmar el apagado.

## Opcion grafica: OpenCode Desktop

Utiliza este recorrido cuando quieras trabajar en OpenCode Desktop.

1. Abre una terminal y ejecuta `opencode-gpu plan` para revisar la seleccion y
   el precio. Este paso no crea un pod.
2. Abre el menu de aplicaciones de Ubuntu.
3. Ejecuta **Start OpenCode private GPU**.
4. Espera la notificacion **Private GPU ready on 127.0.0.1:18000**. La primera
   notificacion solo confirma que el arranque ha comenzado; todavia no debes
   usar el modelo.
5. Abre OpenCode Desktop, o vuelve a su ventana si ya estaba abierto.
6. Selecciona `private-gpu` en el selector de agentes de OpenCode.
7. Confirma que el modelo indicado sea el proveedor privado de Runpod y empieza
   a trabajar.
8. Al terminar, ejecuta **Stop OpenCode private GPU** desde el menu de
   aplicaciones.
9. Espera la notificacion **Private GPU terminated** y comprueba en una
   terminal:

   ```bash
   opencode-gpu status
   ```

OpenCode carga su configuracion al arrancar. Si `private-gpu` no aparece, cierra
OpenCode por completo y vuelve a abrirlo. No hace falta reiniciarlo entre
sesiones normales si el agente ya aparece.

El modo Desktop no vincula el cierre de OpenCode con el apagado del pod. El
ultimo paso, **Stop OpenCode private GPU**, es obligatorio. Ademas, los plugins
ya cargados por Desktop pueden observar la sesion; para el aislamiento mas
estricto usa `opencode-gpu session`.

## Arranque y apagado manuales

Si quieres mantener el pod activo mientras abres y cierras OpenCode por tu
cuenta:

```bash
opencode-gpu plan
opencode-gpu up
opencode --agent private-gpu
opencode-gpu down
```

No ejecutes `opencode --agent private-gpu` hasta que `opencode-gpu up` haya
terminado y mostrado que la API esta lista. Usa siempre `down` al finalizar:
detiene el tunel y **termina** el pod, en vez de limitarse a pararlo.

## Comprobaciones durante una sesion

Consulta el estado local y remoto:

```bash
opencode-gpu status
```

En una sesion lista para trabajar, `tunnel` e `idle_monitor` deben aparecer como
`running`, y el estado de Runpod debe indicar que el pod esta en ejecucion.

Sigue el registro del servidor de inferencia:

```bash
opencode-gpu logs
```

Pulsa `Ctrl-C` para dejar de seguir el registro. Esto no termina el pod.
En modo clinico, llama.cpp desactiva su registro y este comando muestra
principalmente mensajes de arranque, no prompts ni respuestas.

Ejecuta una prueba opcional del servidor:

```bash
opencode-gpu benchmark
```

El benchmark consume tiempo de GPU y no es necesario para el uso normal.

## Limites y costes configurados

La configuracion activa de este Ubuntu se encuentra en:

```text
~/.config/opencode-gpu/config
```

Actualmente esta preparada para usar `llama.cpp`, GPUs de Secure Cloud en
`EU-RO-1` y una cache de modelo en un volumen de red. Los limites principales
son:

- precio maximo admitido: 1,50 USD por hora de GPU;
- contexto maximo universal: 131.072 tokens, con hasta 8.192 tokens de salida;
- terminacion por inactividad de inferencia: 30 minutos;
- terminacion forzosa del pod: 240 minutos;
- solo se publica SSH; la API de inferencia no se expone directamente a
  Internet;
- modo clinico activado de forma predeterminada;
- volumen persistente reservado al GGUF publico, con acceso de solo lectura para
  el proceso de inferencia.

Si se reserva la salida maxima, quedan hasta 122.880 tokens para la entrada. Los
historiales cercanos al limite tardan sensiblemente mas en procesarse, aunque la
respuesta solicitada sea corta.

El inventario y el precio concretos cambian. `opencode-gpu plan` es la
comprobacion valida para cada sesion.

Runpod monta tecnicamente el volumen con escritura para que el proceso de
arranque pueda verificar o completar el GGUF. El servidor se ejecuta con otro
usuario que no puede escribir en `/workspace`. No guardes alli bases de datos,
prompts, resultados ni credenciales. Estas protecciones tecnicas no sustituyen
la aprobacion de la organizacion ni la DPA aplicable a datos clinicos.

La terminacion por inactividad puede ocurrir mientras lees o redactas sin enviar
peticiones al modelo. Si han pasado 30 minutos, ejecuta `opencode-gpu status`
antes de continuar. El volumen de red persiste y puede seguir generando coste de
almacenamiento aunque el pod este apagado.

## Si algo falla

### OpenCode no puede conectar con el modelo

1. Ejecuta `opencode-gpu status`.
2. Si muestra `Status: down`, inicia una nueva sesion.
3. Si el pod existe pero `tunnel` aparece como `stopped`, termina el recurso con
   `opencode-gpu down` y vuelve a empezar.
4. Si usas Desktop, confirma que seleccionaste `private-gpu`, no un proveedor
   externo.

### El arranque dice que ya existe estado local

Ejecuta:

```bash
opencode-gpu status
opencode-gpu down
```

Despues confirma `Status: down` antes de volver a ejecutar `up` o `session`.

### El arranque tarda demasiado o falla

Consulta estos archivos:

```text
~/.local/state/opencode-gpu/startup-failure.log
~/.local/state/opencode-gpu/startup-failure-remote.log
~/.local/state/opencode-gpu/tunnel.log
~/.local/state/opencode-gpu/desktop-up.log
```

Comprueba tambien los recursos de Runpod:

```bash
runpodctl pod list --all
opencode-gpu down
```

No borres manualmente
`~/.local/state/opencode-gpu/state.json`: podria ocultar un pod que sigue
facturando. Conserva el estado hasta que `opencode-gpu down` confirme la
terminacion.

### El apagado no puede confirmar la terminacion

Repite:

```bash
opencode-gpu down
runpodctl pod list --all
```

Si Runpod sigue mostrando el pod, terminalo desde la consola de Runpod y vuelve
a ejecutar `opencode-gpu down` para reconciliar el estado local. No des por
terminada la sesion hasta comprobar que el pod ya no esta activo.

## Comprobacion inicial, solo si cambia la instalacion

No es parte del uso diario. Despues de reinstalar, cambiar credenciales o
actualizar OpenCode, comprueba:

```bash
runpodctl doctor
opencode debug agent private-gpu
```

`runpodctl doctor` debe validar la API y la clave SSH. El segundo comando debe
mostrar el modelo `runpod-private/qwen3.8-27b-fp8`. Tras modificar la
configuracion de OpenCode, cierralo por completo y vuelve a iniciarlo.
