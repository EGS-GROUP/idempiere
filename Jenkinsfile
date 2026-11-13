pipeline {
    // Ejecutor 0 en Built-In Node: este pipeline delega cada stage a contenedores dentro de docker:dind
    agent none

    options {
        // Conserva solo las últimas 10 ejecuciones para no saturar el disco del VPS
        buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '5'))
        // Evita ejecuciones paralelas que compitan por los 2 vCPU y 8 GB libres
        disableConcurrentBuilds()
        // Tiempo máximo de seguridad para compilaciones Tycho extensas
        timeout(time: 45, unit: 'MINUTES')
        timestamps()
    }

    environment {
        // Ajusta el nombre exacto del volumen creado por Dokploy (verifícalo con: docker volume ls)
        MAVEN_CACHE_VOL = 'jenkins-idempiere_maven-repo'
        // Límite de memoria estricta para Maven/Tycho (protege el VPS de 12 GB RAM)
        MAVEN_OPTS      = '-Xmx5g -Xms1g -XX:+UseG1GC -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn'
        // Configuración de la imagen Docker resultante
        DOCKER_REGISTRY = 'ghcr.io/tu-usuario' // O tu Docker Hub / Registry privado
        IMAGE_NAME      = 'idempiere-custom'
        IMAGE_TAG       = "${env.BRANCH_NAME}-${env.BUILD_NUMBER}"
    }

    stages {
        stage('1. Compilar y Empaquetar (Maven + Eclipse Tycho)') {
            agent {
                docker {
                    // Imagen multi-arquitectura (compatible con AMD64 y ARM64 Ampere de Oracle Cloud)
                    image 'maven:3.9.9-eclipse-temurin-17'
                    // Monta el volumen de caché en /var/maven-repo para evitar conflictos de permisos con /root/.m2
                    args "-v ${MAVEN_CACHE_VOL}:/var/maven-repo -e MAVEN_CONFIG=/var/maven-repo"
                    reuseNode true
                }
            }
            steps {
                echo "Iniciando compilación Tycho para rama: ${env.BRANCH_NAME} (Build #${env.BUILD_NUMBER})"
                sh '''
                    mvn clean verify \
                        -Dmaven.repo.local=/var/maven-repo/repository \
                        -Dtycho.localArtifacts=ignore \
                        -Dmaven.test.skip=false \
                        --batch-mode \
                        --errors
                '''
            }
            post {
                success {
                    // Archiva el JAR del plugin o el ZIP/tar.gz del producto P2 generado por Tycho
                    archiveArtifacts artifacts: '**/target/*.jar, **/target/products/*.zip, **/target/products/*.tar.gz',
                                     allowEmptyArchive: true,
                                     fingerprint: true
                }
            }
        }

        stage('2. Construir y Publicar Imagen Docker') {
            // Solo construye imagen final en ramas principales (main o release)
            when {
                anyOf {
                    branch 'main'
                    branch 'master'
                    branch 'release/*'
                }
            }
            agent {
                docker {
                    // Usa el CLI de Docker dentro de dind conectado al daemon aislado por TLS
                    image 'docker:27-cli'
                    args '-e DOCKER_HOST=tcp://docker:2376 -e DOCKER_CERT_PATH=/certs/client -e DOCKER_TLS_VERIFY=1 -v jenkins-idempiere_jenkins-docker-certs:/certs/client:ro'
                    reuseNode true
                }
            }
            steps {
                script {
                    echo "Construyendo imagen ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
                    
                    // Construye la imagen tomando el Dockerfile de tu proyecto iDempiere
                    sh """
                        docker build \
                            --build-arg BUILD_NUMBER=${env.BUILD_NUMBER} \
                            -t ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} \
                            -t ${DOCKER_REGISTRY}/${IMAGE_NAME}:latest \
                            .
                    """

                    // Publicar en el registro (requiere credencial 'docker-registry-creds' en Jenkins)
                    withCredentials([usernamePassword(
                        credentialsId: 'docker-registry-creds',
                        usernameVariable: 'REG_USER',
                        passwordVariable: 'REG_PASS'
                    )]) {
                        sh '''
                            echo "$REG_PASS" | docker login ghcr.io -u "$REG_USER" --password-stdin
                            docker push ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
                            docker push ${DOCKER_REGISTRY}/${IMAGE_NAME}:latest
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            // Limpia imágenes huérfanas (dangling) dentro de dind sin tocar las capas base ni el volumen .m2
            script {
                echo 'Ejecutando limpieza de imágenes intermedias en el daemon dind...'
            }
        }
        success {
            echo "Pipeline finalizado exitosamente: ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        }
        failure {
            echo "Fallo en la compilación o empaquetado de iDempiere. Revisa la salida de Maven/Tycho."
        }
    }
}