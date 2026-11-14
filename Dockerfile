# practice-executor: the API (`python -m app.main`) and the dispatcher (`python -m app.dispatcher`).
# Neither runs submitted code in-process; the dispatcher starts sandbox pods (sandbox/Dockerfile).
FROM python:3.13-slim

WORKDIR /srv
# The versions live in pyproject.toml only (the tests install from it too), so the image runs what was tested.
COPY pyproject.toml ./
RUN python -c "import tomllib; print(*tomllib.load(open('pyproject.toml', 'rb'))['project']['dependencies'], sep=chr(10))" > requirements.txt \
    && pip install --no-cache-dir -r requirements.txt \
    && rm requirements.txt
COPY app ./app
COPY sandbox/runner.py ./sandbox/runner.py

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 10001:10001
EXPOSE 8080
CMD ["python", "-m", "app.main"]
