#!/usr/bin/env bash
# Script de despliegue automático para Tomcat 10
# Función: actualizar repo -> compilar servlet -> empaquetar WAR -> desplegar en Tomcat -> comprobar que responde

set -e  # Si un comando falla, el script termina (evita despliegues a medias)

# -----------------------------
# 1) Variables configurables
# -----------------------------
APP_NAME="hola"                 # Nombre del contexto de la app (saldrá /hola/)
SRC_DIR="src"                   # Carpeta donde están los .java
BUILD_DIR="build"               # Carpeta temporal de compilación
WAR_FILE="${APP_NAME}.war"      # Nombre del WAR a generar

TOMCAT_WEBAPPS="/var/lib/tomcat10/webapps"      # Carpeta donde Tomcat despliega apps
TOMCAT_SERVICE="tomcat10"                      # Nombre del servicio systemd
HEALTH_URL="http://localhost:8080/${APP_NAME}/" # URL para comprobar que funciona

# -----------------------------
# 2) Comprobación de comandos necesarios
# -----------------------------
# 'command -v' comprueba si el comando existe en el sistema
for cmd in git javac jar curl sudo; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Falta el comando: $cmd"; exit 1; }
done

# -----------------------------
# 3) Localizar la librería Servlet API (Jakarta) de Tomcat 10
# -----------------------------
# Tomcat 10 usa 'jakarta.*' (no javax.*). Para compilar, necesitamos el JAR de la API.
# Buscamos un archivo tipo jakarta.servlet-api*.jar en rutas típicas.
SERVLET_API_JAR="$(ls -1 /usr/share/tomcat10/lib/jakarta.servlet-api*.jar 2>/dev/null | head -n 1 || true)"

# Si no aparece ahí, probamos en /var/lib/tomcat10/lib (a veces cambia según distro)
if [ -z "$SERVLET_API_JAR" ]; then
  SERVLET_API_JAR="$(ls -1 /var/lib/tomcat10/lib/jakarta.servlet-api*.jar 2>/dev/null | head -n 1 || true)"
fi

# Si sigue vacío, abortamos con mensaje claro
if [ -z "$SERVLET_API_JAR" ]; then
  echo "No encuentro jakarta.servlet-api*.jar. Revisa instalación de tomcat10."
  echo "Pistas: ls /usr/share/tomcat10/lib | grep jakarta.servlet-api"
  exit 1
fi

echo "[deploy] Usando Servlet API JAR: $SERVLET_API_JAR"

# -----------------------------
# 4) Actualizar el repositorio (si esto es un repo git)
# -----------------------------
# Si estás en una carpeta que NO es repo, git pull fallará.
# Con este comando te aseguras de desplegar la última versión.
echo "[deploy] Actualizando código desde Git..."
git pull --rebase

# -----------------------------
# 5) Preparar carpeta de build
# -----------------------------
# Para un WAR, la estructura estándar es:
# build/
# └── WEB-INF/
#     └── classes/   (aquí van los .class compilados)
echo "[deploy] Preparando carpeta build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/WEB-INF/classes"

# -----------------------------
# 6) Compilar todos los .java
# -----------------------------
# -cp: classpath con la librería Servlet API (Jakarta)
# -d : carpeta destino para los .class
echo "[deploy] Compilando código Java..."
find "$SRC_DIR" -name "*.java" > "$BUILD_DIR/sources.txt"

# Si el archivo sources.txt está vacío, no hay nada que compilar
if [ ! -s "$BUILD_DIR/sources.txt" ]; then
  echo "No hay archivos .java en $SRC_DIR"
  exit 1
fi

javac -cp "$SERVLET_API_JAR" \
  -d "$BUILD_DIR/WEB-INF/classes" \
  @"$BUILD_DIR/sources.txt"

# -----------------------------
# 7) Empaquetar WAR
# -----------------------------
# 'jar -cf' crea un archivo .war (en realidad es un .jar con estructura web)
echo "[deploy] Generando WAR: $WAR_FILE"
rm -f "$WAR_FILE"
( cd "$BUILD_DIR" && jar -cf "../$WAR_FILE" . )

# -----------------------------
# 8) Desplegar en Tomcat (copiar WAR a webapps)
# -----------------------------
# Tomcat despliega automáticamente cualquier WAR que pongas en webapps/
echo "[deploy] Copiando WAR a Tomcat webapps..."
sudo cp "$WAR_FILE" "$TOMCAT_WEBAPPS/$WAR_FILE"

# -----------------------------
# 9) Reiniciar Tomcat
# -----------------------------
echo "[deploy] Reiniciando Tomcat..."
sudo systemctl restart "$TOMCAT_SERVICE"

# -----------------------------
# 10) Healthcheck: comprobar que responde la URL
# -----------------------------
# Esperamos un poco porque Tomcat puede tardar unos segundos en desplegar el WAR.
echo "[deploy] Comprobando URL: $HEALTH_URL"
for i in {1..20}; do
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    echo "[deploy] OK: la aplicación responde en $HEALTH_URL"
    exit 0
  fi
  sleep 1
done

echo "[deploy] ERROR: la aplicación no respondió a tiempo."
echo "Revisa logs: sudo journalctl -u $TOMCAT_SERVICE -n 200 --no-pager"
exit 1
