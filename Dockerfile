# Build stage
FROM golang:1.23-alpine AS builder

WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app/server .

# Run stage
FROM alpine:3.20

WORKDIR /app
COPY --from=builder /app/server /app/server
EXPOSE 8080
ENTRYPOINT ["/app/server"]
