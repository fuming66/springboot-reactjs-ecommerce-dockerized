#!/bin/bash
set -euo pipefail

# 生成不会冲突的分支名（add-docker-build-<timestamp>）
BASE_BRANCH="add-docker-build"
TS=$(date +%s)
BRANCH="${BASE_BRANCH}-${TS}"

echo "Creating branch: $BRANCH"

# 确保在 git 仓库根
if [ ! -d ".git" ]; then
  echo "Error: 当前目录不是 git 仓库，请先切换到仓库根目录再运行脚本。"
  exit 1
fi

# 检查工作区是否干净
if [ -n "$(git status --porcelain)" ]; then
  echo "Error: 工作区有未提交的改动，请先提交或 stash 再运行脚本。"
  git status --porcelain
  exit 1
fi

# 创建并切换到新分支
git checkout -b "$BRANCH"

# 创建目录结构
mkdir -p .github/workflows docker

# 写 workflow 文件
cat > .github/workflows/build-and-release.yml <<'YML'
name: Build and Release Docker-ready ZIP
on:
  workflow_dispatch:

jobs:
  build_and_package:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout this repo
        uses: actions/checkout@v4

      - name: Clone upstream e-commerce repo
        run: |
          git clone --depth 1 https://github.com/GattiHarishKumar/SpringBoot-Reactjs-Ecommerce.git upstream

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - name: Build backend (Maven)
        run: |
          cd upstream/Ecommerce-Backend
          mvn -B -DskipTests package

      - name: Set up Node 18
        uses: actions/setup-node@v4
        with:
          node-version: 18

      - name: Build frontend (Vite)
        run: |
          cd upstream/Ecommerce-Frontend
          npm ci
          npm run build

      - name: Prepare package directory
        run: |
          mkdir -p package/docker
          cp upstream/Ecommerce-Backend/target/*.jar package/backend.jar || true
          if [ -d upstream/Ecommerce-Frontend/dist ]; then
            cp -r upstream/Ecommerce-Frontend/dist package/frontend
          elif [ -d upstream/Ecommerce-Frontend/build ]; then
            cp -r upstream/Ecommerce-Frontend/build package/frontend
          else
            echo "Frontend build dir not found" && exit 1
          fi

      - name: Add Dockerfiles and docker-compose
        run: |
          cat > package/docker/backend.Dockerfile <<'EOF'
          FROM eclipse-temurin:17-jre-alpine
          WORKDIR /app
          COPY backend.jar app.jar
          EXPOSE 8080
          ENTRYPOINT ["java","-jar","/app/app.jar"]
          EOF

          cat > package/docker/nginx.Dockerfile <<'EOF'
          FROM nginx:alpine
          COPY frontend /usr/share/nginx/html
          EXPOSE 80
          EOF

          cat > package/docker-compose.yml <<'EOF'
          version: '3.8'
          services:
            db:
              image: mysql:8.0
              environment:
                MYSQL_DATABASE: ecomdb
                MYSQL_ROOT_PASSWORD: password123
              volumes:
                - db_data:/var/lib/mysql
              ports:
                - "3306:3306"

            backend:
              build:
                context: .
                dockerfile: docker/backend.Dockerfile
              environment:
                SPRING_DATASOURCE_URL: jdbc:mysql://db:3306/ecomdb
                SPRING_DATASOURCE_USERNAME: root
                SPRING_DATASOURCE_PASSWORD: password123
              ports:
                - "8080:8080"
              depends_on:
                - db

            frontend:
              build:
                context: .
                dockerfile: docker/nginx.Dockerfile
              ports:
                - "80:80"
              depends_on:
                - backend

          volumes:
            db_data:
          EOF

      - name: Copy helper files
        run: |
          cat > package/.env.example <<'EOF'
          MYSQL_DATABASE=ecomdb
          MYSQL_ROOT_PASSWORD=password123
          SPRING_DATASOURCE_URL=jdbc:mysql://db:3306/ecomdb
          SPRING_DATASOURCE_USERNAME=root
          SPRING_DATASOURCE_PASSWORD=password123
          EOF

          cat > package/README.md <<'EOF'
          Docker-ready package for SpringBoot-Reactjs-Ecommerce

          Contents:
          - backend.jar : built Spring Boot application
          - frontend/ : built frontend static files
          - docker/ : Dockerfiles for backend and nginx
          - docker-compose.yml : compose file to run backend, frontend (nginx) and MySQL
          - .env.example : example env variables
          EOF

      - name: Create ZIP
        run: |
          cd package
          zip -r ../ecom-docker-ready.zip .

      - name: Create GitHub Release
        id: create_release
        uses: actions/create-release@v1
        with:
          tag_name: docker-ready-1
          release_name: Docker-ready build
          body: "Docker-ready build (backend.jar + frontend) for SpringBoot-Reactjs-Ecommerce"
          draft: false
          prerelease: false
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Upload ZIP to Release
        uses: actions/upload-release-asset@v1
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./ecom-docker-ready.zip
          asset_name: ecom-docker-ready.zip
          asset_content_type: application/zip
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
YML

# 写 docker 文件与 .env.example
cat > docker/backend.Dockerfile <<'DF'
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY backend.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","/app/app.jar"]
DF

cat > docker/nginx.Dockerfile <<'DF'
FROM nginx:alpine
COPY frontend /usr/share/nginx/html
EXPOSE 80
DF

cat > .env.example <<'ENV'
# Example environment variables for docker-compose
MYSQL_DATABASE=ecomdb
MYSQL_ROOT_PASSWORD=password123
SPRING_DATASOURCE_URL=jdbc:mysql://db:3306/ecomdb
SPRING_DATASOURCE_USERNAME=root
SPRING_DATASOURCE_PASSWORD=password123
ENV

# 提交并 push
git add .
git commit -m "Add CI workflow, dockerfiles and packaging"
echo "Pushing branch $BRANCH to origin..."
if git push -u origin "$BRANCH"; then
  echo "Push 成功。远端分支： $BRANCH"
  echo "请到 GitHub 创建 Pull Request 并合并，或在 Actions 手动 Run workflow。"
else
  echo "git push 失败。请检查权限（HTTPS 使用 PAT 或配置 SSH key）。"
  echo "如果需要我可以帮你排查具体的错误，请把 push 的错误信息贴给我。"
  exit 2

fi
