gunicorn -w 4 \
    -k gevent \
    --worker-connections 1000 \
    -b 0.0.0.0:5000 \
    --timeout 600 \
    --graceful-timeout 30 \
    --keep-alive 5 \
    --log-level info \
    monitor-v7:app
