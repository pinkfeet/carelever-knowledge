#!/bin/bash
docker system prune -a -f
export AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep region | cut -d\" -f4)
export AWS_ACCOUNT=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep accountId | cut -d\" -f4)
export DISABLE_PRY_RAILS=1
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_CTYPE=UTF-8
$(aws ecr get-login --no-include-email --registry-ids ${AWS_ACCOUNT} --region $AWS_DEFAULT_REGION)
PS3='Please enter your choice: '
options=("Rails Console" "Quit")
select opt in "${options[@]}"
do
    case $opt in
        "Rails Console")
            PS3='For which product? '
            options2=("authentication" "billing" "calendar" "cloudhealth" "company" "form" "manage" "monitoring" "organisation" "reports" "screen" "comply" "hub-manage", "assessment")
            select opt in "${options2[@]}"
            do
                case $opt in
                    "authentication")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/authentication:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "billing")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/billing:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "calendar")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/calendar:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "cloudhealth")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/cloudhealth:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "company")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/company:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "form")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/form:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "manage")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/manage:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "monitoring")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/monitoring:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "organisation")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/organisation:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "reports")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/reports:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "screen")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/screen:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;

                    "comply")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/comply:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "hub-manage")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/hub-manage:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    "assessment")
                    echo "Launching - Use Ctrl + D to exit"
                    # using latest as thats production I believe
                    container="477332033800.dkr.ecr.ap-southeast-2.amazonaws.com/assessment:latest"
                    echo "Container: ${container} being utilised"
                    docker run -it --rm ${container} /bin/bash -c 'bundle exec rails console'
                    break
                    ;;
                    
                esac
            done
            break
            ;;
        "Quit")
            break
            ;;
        *) echo "invalid option $REPLY";;
    esac
done

