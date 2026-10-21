# Lightweight Node.js 20 base image
FROM node:20-alpine

# Working directory inside container
WORKDIR /app

# Copy package files first (for Docker layer caching)
COPY package*.json ./

# Install production dependencies only
RUN npm install --omit=dev

# Copy all project files into the container
COPY . .

# Expose port 3000 for the app
EXPOSE 3000

# Start the application
CMD ["node", "server.js"]
