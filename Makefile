.PHONY: ssl_keys

ssl_keys:
	mkdir -p priv/cert
	openssl genrsa -out priv/cert/ca_key.pem 2048
	openssl req -x509 -new -nodes -key priv/cert/ca_key.pem -sha256 -days 1024 -out priv/cert/ca.pem -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"
	openssl genrsa -out priv/cert/server.pem 2048
	openssl req -new -key priv/cert/server.pem -out priv/cert/server.csr -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"
	openssl x509 -req -in priv/cert/server.csr -CA priv/cert/ca.pem -CAkey priv/cert/ca_key.pem -CAcreateserial -out priv/cert/server.crt -days 365 -sha256
	rm -f priv/cert/server.csr
	rm -f priv/cert/ca.srl

clean:
	rm -rf priv/ssl
