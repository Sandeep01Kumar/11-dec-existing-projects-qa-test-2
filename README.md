# hao-backprop-test

A simple Node.js HTTP server built with Express.js framework.

## Description

This project demonstrates a basic Express.js web server with two HTTP endpoints. Originally using the native Node.js `http` module, it has been upgraded to use Express.js for improved routing and developer experience.

## Prerequisites

- Node.js (v18 or higher)
- npm (v8 or higher)

## Installation

Install the project dependencies by running:

```bash
npm install
```

This will install Express.js and all required dependencies.

## Starting the Server

Start the server using one of the following commands:

```bash
node server.js
```

Or using npm:

```bash
npm start
```

The server will start and listen on `http://127.0.0.1:3000/`.

You should see the following output in your console:

```
Server running at http://127.0.0.1:3000/
```

## Available Endpoints

### GET /

Returns a hello world greeting.

**Request:**
```bash
curl http://127.0.0.1:3000/
```

**Response:**
```
Hello, World!
```

### GET /evening

Returns an evening greeting.

**Request:**
```bash
curl http://127.0.0.1:3000/evening
```

**Response:**
```
Good evening
```

## Testing the Endpoints

You can test the endpoints using `curl` or any HTTP client:

```bash
# Test the root endpoint
curl http://127.0.0.1:3000/

# Test the evening endpoint
curl http://127.0.0.1:3000/evening
```

## Project Structure

```
├── server.js          # Express.js server with route handlers
├── package.json       # npm package configuration with dependencies
├── package-lock.json  # Dependency version lock file
├── README.md          # Project documentation
└── node_modules/      # Installed dependencies (generated)
```

## License

This is a test project for backprop integration.
