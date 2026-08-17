ARG NODE_VERSION=22-alpine
ARG NGINX_VERSION=1.27-alpine


FROM node:${NODE_VERSION} AS build

WORKDIR /app

COPY package.json package-lock.json ./

RUN npm ci

COPY vite.config.js index.html ./
COPY public ./public
COPY src ./src

RUN npm run build

FROM nginx:${NGINX_VERSION} AS runtime

COPY nginx.conf /etc/nginx/conf.d/default.conf


COPY --from=build /app/dist /usr/share/nginx/html


COPY docker-entrypoint.d/10-runtime-config.sh /docker-entrypoint.d/10-runtime-config.sh
RUN chmod +x /docker-entrypoint.d/10-runtime-config.sh

ENV API_BASE_URL=/api \
    APP_TITLE="Docker Practice Shop"

EXPOSE 80

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

# No CMD/ENTRYPOINT needed: we inherit nginx's, which runs the
# /docker-entrypoint.d hooks and then `exec nginx -g 'daemon off;'`.
#
# NOTE the `daemon off`: a container needs its main process to stay in the
# FOREGROUND. If nginx daemonised, PID 1 would exit immediately and Docker
# would consider the container finished. Same rule for every service you
# containerise -- never background the main process.
