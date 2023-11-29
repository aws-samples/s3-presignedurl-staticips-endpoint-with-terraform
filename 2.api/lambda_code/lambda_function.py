import os
import boto3

# bucket_name = 'example-endpoint.apg-scratchers.store'
bucket_name = os.environ['BUCKET_NAME']
endpoint_url = 'https://' + bucket_name
s3_client = boto3.client('s3', config=boto3.session.Config(signature_version='s3v4', ))
s3_client_for_endpoint = boto3.client(
    service_name='s3',
    endpoint_url=endpoint_url
)


def lambda_handler(event, context):
    request_path = event['path'].split('/')

    presigned_url = s3_client_for_endpoint.generate_presigned_url(
        'get_object',
        Params={'Bucket': request_path[1], 'Key': '/'.join(request_path[2:])},
        ExpiresIn=3600
    )

    return {
        'statusCode': 302,
        'headers': {'Location': f'{presigned_url}'}
    }

