import os
from fastapi import FastAPI

app = FastAPI()

APP_VERSION = os.getenv("APP_VERSION", "unknown")


@app.get("/")
def root():
    return {"status": "success", "message": "FinCorp API is running"}


@app.get("/healthz")
def healthz():
    return {"status": "healthy", "version": APP_VERSION}
