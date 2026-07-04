FROM ghcr.io/gmeligio/flutter-web:3.44.4 AS flutter-build

WORKDIR /app
RUN chown flutter:flutter /app
USER flutter

COPY --chown=flutter:flutter pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY --chown=flutter:flutter . .
RUN flutter build web --release

FROM node:20-alpine

WORKDIR /app

COPY backend/package.json ./backend/package.json
COPY backend/package-lock.json ./backend/package-lock.json
RUN npm --prefix backend ci --omit=dev

COPY backend ./backend
COPY --from=flutter-build /app/build/web ./build/web

WORKDIR /app/backend
ENV NODE_ENV=production

CMD ["npm", "start"]
