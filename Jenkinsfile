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
        BRANCH_TAG      = "${env.BRANCH_NAME ?: (env.GIT_BRANCH ? env.GIT_BRANCH.replace('origin/', '') : 'lunaerp-jenkins')}"
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
                    branch 'lunaerpqa-jenkins'
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
                    def isQA = (BRANCH_TAG == 'lunaerpqa-jenkins' || BRANCH_TAG.contains('qa'))
                    def floatTag = isQA ? 'qa' : 'latest'

                    echo "Construyendo imagen ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} (Tag flotante: :${floatTag})"
                    sh """
                        docker build \
                            --build-arg BUILD_NUMBER=${env.BUILD_NUMBER} \
                            -t ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} \
                            -t ${DOCKER_REGISTRY}/${IMAGE_NAME}:${floatTag} \
                            .
                    """

                    withCredentials([usernamePassword(
                        credentialsId: 'docker-registry-creds',
                        usernameVariable: 'REG_USER',
                        passwordVariable: 'REG_PASS'
                    )]) {
                        sh """
                            echo "\$REG_PASS" | docker login registry.egssmart.com -u "\$REG_USER" --password-stdin
                            docker push ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
                            docker push ${DOCKER_REGISTRY}/${IMAGE_NAME}:${floatTag}
                        """
                    }
                }
            }
        }
        stage('3. Desplegar en Dokploy (CD)') {
            when {
                anyOf {
                    branch 'lunaerp-jenkins'
                    branch 'lunaerpqa-jenkins'
                    branch 'main'
                    branch 'release/*'
                    expression { return env.BRANCH_NAME == null }
                }
            }
            agent any
            steps {
                script {
                    def isQA = (BRANCH_TAG == 'lunaerpqa-jenkins' || BRANCH_TAG.contains('qa'))
                    def webhookUrl = isQA ? 'https://deploylunaerpqa.egssmart.com/api/deploy/compose/ehOgII7lsVvaM_EyAE2cn'
                                          : 'https://deploylunaerp.egssmart.com/api/deploy/compose/DpdJbmbdBswM92kMsW3df'
                    def envName = isQA ? 'QA (deploylunaerpqa)' : 'Producción/Staging (deploylunaerp)'

                    echo "Notificando a Dokploy ${envName} para descargar nueva imagen (${isQA ? ':qa' : ':latest'}) y reiniciar..."
                    sh "curl -s -X POST '${webhookUrl}'"
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
