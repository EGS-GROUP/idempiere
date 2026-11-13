# Guía de Arquitectura y Pipeline CI/CD con Jenkins para LunaERP (iDempiere)

Este documento describe la arquitectura, decisiones de diseño, configuración paso a paso y mejores prácticas implementadas para compilar, empaquetar y publicar **LunaERP (iDempiere Core)** de forma automatizada mediante **Jenkins** y **Docker en Dokploy / VPS**.

---

## 1. Visión General de la Arquitectura

```
  +---------------------------------------------------------------------------------+
  | VPS Host (12 GB RAM / Dokploy / Docker)                                         |
  |                                                                                 |
  |  +--------------------+                                                         |
  |  |  jenkins-dind      | <------- docker.sock / TLS                              |
  |  +---------+----------+                                                         |
  |            |                                                                    |
  |            v                                                                    |
  |  +---------------------------------------------------------------------------+  |
  |  | Stage 1: Maven + Tycho Container (maven:3.9.9-eclipse-temurin-17)        |  |
  |  |   - Caché persistente en volumen: maven-m2-cache -> /var/maven-repo       |  |
  |  |   - Compilación P2 / OSGi -> Generación de producto en org.idempiere.p2   |  |
  |  +-------------------------------------+-------------------------------------+  |
  |                                        |                                        |
  |                                        v                                        |
  |  +---------------------------------------------------------------------------+  |
  |  | Stage 2: Docker CLI Container (docker:27-cli)                             |  |
  |  |   - Contexto optimizado (.dockerignore)                                   |  |
  |  |   - Construcción de imagen LunaERP (eclipse-temurin:17-jre-jammy)        |  |
  |  |   - Autenticación segura y push hacia Registry Soberano                   |  |
  |  +-------------------------------------+-------------------------------------+  |
  +----------------------------------------|----------------------------------------+
                                           |
                                           v
           +---------------------------------------------------------------+
           | Private Registry: registry.egssmart.com/egs-group/lunaerp-... |
           +---------------------------------------------------------------+
```

---

## 2. Decisiones Técnicas Clave y Resolución de Problemas

### 2.1. Caché Maven/Tycho sin conflictos de permisos (`/var/maven-repo`)
* **Problema:** Montar el volumen en `/root/.m2` ocasiona errores de permisos (`Permission Denied` o `EACCES`) cuando el contenedor de Jenkins ejecuta procesos con el usuario Jenkins no-root (`UID 1000`), o cuando se alternan contenedores con diferentes UIDs.
* **Solución aplicada:** 
  - Se monta el volumen en una ruta neutral: `-v maven-m2-cache:/var/maven-repo`.
  - Se define la variable de entorno de Maven: `-e MAVEN_CONFIG=/var/maven-repo`.
  - Se instruye explícitamente a Maven en el comando con `-Dmaven.repo.local=/var/maven-repo/repository`.
  - Esto garantiza que las dependencias, plugins y artefactos P2 descargados se mantengan intactos entre builds sin corromper permisos.

### 2.2. Gestión de Tiempos de Espera (Timeouts de 90 minutos)
* **Problema:** En la primera ejecución o tras invalidar la caché, Eclipse Tycho descarga cientos de artefactos P2 desde repositorios remotos (Eclipse Equinox, Orbit, etc.), superando los 45 minutos habituales.
* **Solución aplicada:** Se amplió `timeout(time: 90, unit: 'MINUTES')` en las opciones del pipeline.
* **Optimización de compilación:** Se incorporó `-Dmaven.test.skip=true` y `-Dtycho.localArtifacts=ignore` para acelerar el empaquetado del producto final.

### 2.3. Soporte Híbrido: Pipeline Estándar y Multibranch
* **Problema:** En proyectos configurados como "Pipeline" tradicional en Jenkins, la variable `env.BRANCH_NAME` es `null`, lo que rompía los nombres de etiquetas y las condiciones `when { branch ... }`.
* **Solución aplicada:**
  - Fallback en variables de entorno:
    ```groovy
    BRANCH_TAG = "${env.BRANCH_NAME ?: 'lunaerp-jenkins'}"
    IMAGE_TAG  = "${BRANCH_TAG}-${env.BUILD_NUMBER}"
    ```
  - Expresión tolerante en la cláusula `when` del Stage de Docker:
    ```groovy
    when {
        anyOf {
            branch 'lunaerp-jenkins'
            branch 'main'
            branch 'release/*'
            expression { return env.BRANCH_NAME == null }
        }
    }
    ```

### 2.4. Integración con Registro Privado Soberano
* **Configuración:** Registro alojado en `registry.egssmart.com/egs-group`.
* **Seguridad de credenciales:** Uso de `withCredentials([usernamePassword(...)])` con el ID `docker-registry-creds` almacenado en Jenkins Credentials Store.
* **Login y Push:**
  ```bash
  echo "$REG_PASS" | docker login registry.egssmart.com -u "$REG_USER" --password-stdin
  docker push ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
  docker push ${DOCKER_REGISTRY}/${IMAGE_NAME}:latest
  ```

### 2.5. Desbloqueo de Ejecutores en Built-In Node ("Waiting for next available executor")
* **Problema:** El pipeline se quedaba en cola indefinidamente esperando un ejecutor (`Still waiting to schedule task / Waiting for next available executor`).
* **Causa:** El nodo integrado (*Built-In Node*) de Jenkins en Dokploy tenía configurado `# of executors = 0` y no existían agentes externos registrados.
* **Solución aplicada:** Se configuró el número de ejecutores a `1` en *Administrar Jenkins -> Nodos -> Built-In Node -> Configurar*.

### 2.6. Permisos en el Contenedor Docker CLI (`ERROR: mkdir /.docker: permission denied`)
* **Problema:** En el Stage 2, al ejecutar `docker build`, fallaba con:
  ```text
  ERROR: mkdir /.docker: permission denied
  ```
* **Causa:** Jenkins ejecuta contenedores secundarios pasando por defecto el usuario no-root `UID 1000:1000`. En la imagen `docker:27-cli` (Alpine), el usuario no tiene `$HOME` configurado (apunta a `/`), y la raíz `/` no es modificable por usuarios no-root.
* **Solución aplicada:** Se ajustaron los argumentos del contenedor del Stage 2 para ejecutarse con privilegios (`-u 0:0`) y redirigir la configuración de Docker a un directorio con permisos universales:
  ```groovy
  args '-u 0:0 -v /var/run/docker.sock:/var/run/docker.sock -e DOCKER_CONFIG=/tmp/.docker -e HOME=/tmp'
  ```

---

## 3. Estructura de Archivos del Flujo CI/CD

| Archivo | Función Principal |
|---|---|
| [`Jenkinsfile`](Jenkinsfile) | Orquestación declarativa del ciclo de vida (Build Maven/Tycho -> Empaquetado -> Docker Build -> Docker Push). |
| [`Dockerfile`](Dockerfile) | Imagen final de producción basada en `eclipse-temurin:17-jre-jammy`, con usuario seguro `idempiere`, scripts con permisos de ejecución y puertos 8080/8443/12612 expuestos. |
| [`.dockerignore`](.dockerignore) | Excluye todo el código fuente y artefactos temporales (`*`), admitiendo únicamente el binario generado en `!org.idempiere.p2/target/products/org.adempiere.server.product/linux/gtk/` para un contexto de build ligero y veloz. |

---

## 4. Pipeline Declarativo Completo

El archivo `Jenkinsfile` en producción cuenta con la siguiente estructura:

```groovy
pipeline {
    agent none

    options {
        buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '5'))
        disableConcurrentBuilds()
        // Ampliado a 90 min para la primera descarga completa de repositorios P2 del core de iDempiere
        timeout(time: 90, unit: 'MINUTES')
        timestamps()
    }

    environment {
        MAVEN_CACHE_VOL = 'maven-m2-cache'
        MAVEN_OPTS      = '-Xmx5g -Xms1g -XX:+UseG1GC -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn'
        // Tu registro propio soberano en lugar de ghcr.io
        DOCKER_REGISTRY = 'registry.egssmart.com/egs-group'
        IMAGE_NAME      = 'lunaerp-idempiere'
        BRANCH_TAG      = "${env.BRANCH_NAME ?: 'lunaerp-jenkins'}"
        IMAGE_TAG       = "${BRANCH_TAG}-${env.BUILD_NUMBER}"
    }

    stages {
        stage('1. Compilar y Empaquetar (Maven + Eclipse Tycho)') {
            agent {
                docker {
                    image 'maven:3.9.9-eclipse-temurin-17'
                    args "-v ${MAVEN_CACHE_VOL}:/var/maven-repo -e MAVEN_CONFIG=/var/maven-repo"
                    reuseNode true
                }
            }
            steps {
                echo "Iniciando compilación Tycho de LunaERP para rama: ${BRANCH_TAG} (Build #${env.BUILD_NUMBER})"
                sh '''
                    mvn clean verify \
                        -Dmaven.repo.local=/var/maven-repo/repository \
                        -Dtycho.localArtifacts=ignore \
                        -Dmaven.test.skip=true \
                        --batch-mode \
                        --errors
                '''
            }
            post {
                success {
                    archiveArtifacts artifacts: '**/target/products/*.zip, **/target/products/*.tar.gz',
                                     allowEmptyArchive: true,
                                     fingerprint: true
                }
            }
        }

        stage('2. Construir y Publicar Imagen Docker') {
            when {
                anyOf {
                    branch 'lunaerp-jenkins'
                    branch 'main'
                    branch 'release/*'
                    // Permite ejecución si se usa Pipeline estándar (donde BRANCH_NAME es null)
                    expression { return env.BRANCH_NAME == null }
                }
            }
            agent {
                docker {
                    image 'docker:27-cli'
                    args '-u 0:0 -v /var/run/docker.sock:/var/run/docker.sock -e DOCKER_CONFIG=/tmp/.docker -e HOME=/tmp'
                    reuseNode true
                }
            }
            steps {
                script {
                    echo "Construyendo imagen ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
                    sh """
                        docker build \
                            --build-arg BUILD_NUMBER=${env.BUILD_NUMBER} \
                            -t ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} \
                            -t ${DOCKER_REGISTRY}/${IMAGE_NAME}:latest \
                            .
                    """

                    withCredentials([usernamePassword(
                        credentialsId: 'docker-registry-creds',
                        usernameVariable: 'REG_USER',
                        passwordVariable: 'REG_PASS'
                    )]) {
                        sh '''
                            echo "$REG_PASS" | docker login registry.egssmart.com -u "$REG_USER" --password-stdin
                            docker push ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
                            docker push ${DOCKER_REGISTRY}/${IMAGE_NAME}:latest
                        '''
                    }
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline LunaERP finalizado: ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        }
        failure {
            echo "Fallo en la compilación o empaquetado de LunaERP. Revisa la salida de Maven/Tycho."
        }
    }
}
```

---

## 5. Prerequisitos en Jenkins y el Servidor Host

1. **Credenciales en Jenkins:**
   - Tipo: *Username with password*.
   - ID: `docker-registry-creds`.
   - Usuario: Usuario autorizado para publicar en `registry.egssmart.com`.
   - Contraseña / Token: Contraseña o Token de autenticación del registry.
2. **Volumen Docker:**
   - El volumen `maven-m2-cache` debe existir o ser creado por el daemon Docker:
     ```bash
     docker volume create maven-m2-cache
     ```
   - Si se presentan discrepancias de permisos al crearlo por primera vez, asegurar permisos de escritura para usuarios no-root:
     ```bash
     docker run --rm -v maven-m2-cache:/var/maven-repo alpine chmod -R 777 /var/maven-repo
     ```
3. **Acceso al Docker Socket:**
   - Jenkins debe tener montado `/var/run/docker.sock` para que el agente `docker:27-cli` pueda orquestar builds en el daemon subyacente.

---

## 6. Hoja de Ruta / Próximas Fases CI/CD

Conforme avancemos en la automatización, este documento incorporará las siguientes etapas:

- [x] **Fase 1:** Compilación y empaquetado headless con Tycho + Caché `.m2` persistente.
- [x] **Fase 2:** Construcción de imagen Docker no-root y publicación en Registro Soberano.
- [ ] **Fase 3:** Ejecución de migraciones automáticas de base de datos (`RUN_SyncDBDev.sh` / iDempiere migrations).
- [ ] **Fase 4:** Despliegue continuo (CD) automático en entorno Staging / QA (Dokploy webhook / compose restart).
- [ ] **Fase 5:** Notificaciones automáticas a Telegram / Slack / Discord sobre el estado del build.

