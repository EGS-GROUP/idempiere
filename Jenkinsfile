pipeline {
    agent none

    options {
        buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '5'))
        disableConcurrentBuilds()
        timeout(time: 45, unit: 'MINUTES')
        timestamps()
    }

    environment {
        // Volumen interno creado dentro de jenkins-dind con permisos 1000:1000
        MAVEN_CACHE_VOL = 'maven-m2-cache'
        MAVEN_OPTS      = '-Xmx5g -Xms1g -XX:+UseG1GC -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn'
        DOCKER_REGISTRY = 'ghcr.io/tu-usuario'
        IMAGE_NAME      = 'idempiere-custom'
        IMAGE_TAG       = "${env.BRANCH_NAME}-${env.BUILD_NUMBER}"
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
                    archiveArtifacts artifacts: '**/target/*.jar, **/target/products/*.zip, **/target/products/*.tar.gz',
                                     allowEmptyArchive: true,
                                     fingerprint: true
                }
            }
        }

        stage('2. Construir y Publicar Imagen Docker') {
            when {
                anyOf {
                    branch 'main'
                    branch 'master'
                    branch 'release/*'
                }
            }
            agent {
                docker {
                    image 'docker:27-cli'
                    // Se conecta al socket interno de jenkins-dind (ya aislado del VPS host)
                    args '-v /var/run/docker.sock:/var/run/docker.sock'
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
        success {
            echo "Pipeline finalizado exitosamente: ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        }
        failure {
            echo "Fallo en la compilación o empaquetado de iDempiere. Revisa la salida de Maven/Tycho."
        }
    }
}
