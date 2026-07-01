FROM node:20-alpine

WORKDIR /app

COPY backend/package.json ./backend/package.json
COPY backend/package-lock.json ./backend/package-lock.json
RUN npm --prefix backend ci --omit=dev

COPY backend ./backend

WORKDIR /app/backend
ENV NODE_ENV=production

CMD ["npm", "start"]
