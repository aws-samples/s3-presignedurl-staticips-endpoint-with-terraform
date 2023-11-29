import os
import json
import boto3
import re

# bucket_name = 'examplebucket.s3.poc.spatchcardio.com'
bucket_name = os.environ['BUCKET_NAME']
endpoint_url = 'https://' + bucket_name
s3_client = boto3.client('s3', config=boto3.session.Config(signature_version='s3v4',))
s3_client_for_endpoint = boto3.client(
            service_name='s3',
            endpoint_url=endpoint_url
        )
    
regex_pattern = r'\/'
        
def lambda_handler(event, context):
    test_id = event['pathParameters']['testId']
    prefix = f'{test_id}/'
    objects = s3_client.list_objects_v2(Bucket=bucket_name, Prefix=prefix)

    presigned_url = ''
    for obj in objects.get('Contents', []):
        if obj['Key'].endswith('.pdf'):
            obj_path = re.split(regex_pattern, obj['Key'], 1)
            presigned_url = s3_client_for_endpoint.generate_presigned_url(
                'get_object',
                Params={'Bucket': obj_path[0], 'Key': obj_path[1]},
                ExpiresIn=3600
            )
            break
        
    return {
        'statusCode': 302,
        'headers' : {'Location': f'{presigned_url}'}
    }
