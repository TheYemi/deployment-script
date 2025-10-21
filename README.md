Author: Olasehinde Opeyemi

Info: A simple deploy script to 
- clone repo
- check if a dockerfile or docker-compose file exists
- ssh into a provisioned server and perform connectivity checks
- securely copy cloned repo to provisioned server
- install docker and nginx in the server
- build and run docker container based off the docker files provided
- configure nginx as a reverse proxy
- validate deployment
- implement logging and error handling

