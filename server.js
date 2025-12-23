const express = require('express');

const hostname = '127.0.0.1';
const port = 3000;

const app = express();

// Root endpoint - preserves existing "Hello, World!" response
app.get('/', (req, res) => {
  res.send('Hello, World!\n');
});

// New endpoint - returns "Good morning" as specified by user
app.get('/morning', (req, res) => {
  res.send('Good morning');
});

app.listen(port, hostname, () => {
  console.log(`Server running at http://${hostname}:${port}/`);
});
