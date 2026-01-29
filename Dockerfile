FROM node:20-slim AS frontend-builder
WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm install --silent
COPY frontend/ ./
RUN npm run build

FROM python:3.11-bookworm 
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 TZ=Asia/Shanghai

# 安装系统依赖 + 安装 Cloudflare WARP
COPY warp.sh .
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl gnupg lsb-release ca-certificates \
        chromium xvfb xauth dbus-x11 \
        libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
        libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libgbm1 libasound2 && \
    chmod +x warp.sh && \
    ./warp.sh c || true && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
COPY core ./core
COPY util ./util
COPY --from=frontend-builder /app/static ./static
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh
EXPOSE 7860
CMD ["./entrypoint.sh"]
