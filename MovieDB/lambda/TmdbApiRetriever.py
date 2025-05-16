import json
import requests
import boto3
from botocore.exceptions import ClientError
from decimal import Decimal
from datetime import datetime

# Class to handle Decimal types in JSON serialization
class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super(DecimalEncoder, self).default(obj)

# Function to retrieve secrets from AWS Secrets Manager
def get_secret(secret_name):
    session = boto3.session.Session()
    client = session.client(service_name='secretsmanager')

    try:
        get_secret_value_response = client.get_secret_value(SecretId=secret_name)
    except ClientError as e:
        raise e

    secret = get_secret_value_response['SecretString']
    return json.loads(secret)

# Function to fetch genres from TMDb API
def get_genres(tmdb_api_key):
    url = f'https://api.themoviedb.org/3/genre/movie/list?api_key={tmdb_api_key}&language=en-US'
    
    response = requests.get(url)

    if response.status_code != 200:
        print(f"Failed to retrieve genres. Status code: {response.status_code}")
        return {}

    data = response.json()
    genre_mapping = {genre['id']: genre['name'] for genre in data.get('genres', [])}
    return genre_mapping

# Function to fetch trending movies from TMDb API
def get_trending_movies(tmdb_api_key):
    url = f'https://api.themoviedb.org/3/trending/movie/week?api_key={tmdb_api_key}&language=en-US'
    
    response = requests.get(url)

    if response.status_code != 200:
        print(f"Failed to retrieve trending movies. Status code: {response.status_code}")
        return []

    data = response.json()

    if 'results' not in data:
        print("No results found in the response.")
        return []

    movies = []
    for movie in data['results']:
        movies.append({
            'title': movie.get('title', 'N/A'),
            'release_year': movie.get('release_date', 'N/A').split('-')[0] if movie.get('release_date') else 'N/A',
            'tmdb_id': movie.get('id'),
            'rating': Decimal(str(movie.get('vote_average', 0))) if movie.get('vote_average') is not None else Decimal(0),
            'genre_ids': movie.get('genre_ids', []),
            'overview': movie.get('overview', 'N/A'),
            'poster_path': f"https://image.tmdb.org/t/p/w500{movie.get('poster_path')}" if movie.get('poster_path') else None
        })

    return movies

# Function to save movie details to DynamoDB
def save_to_dynamodb(movies, genre_mapping):
    dynamodb = boto3.resource('dynamodb')
    table = dynamodb.Table('TopMovies')

    for movie in movies:
        try:
            genre_names = [genre_mapping.get(genre_id, 'Unknown') for genre_id in movie['genre_ids']]
            timestamp = datetime.utcnow().isoformat()  # Get current UTC time in ISO format
            table.put_item(
                Item={
                    'MovieID': movie['title'],
                    'release_year': movie['release_year'],
                    'rating': movie['rating'],
                    'genres': ', '.join(genre_names),
                    'overview': movie['overview'],
                    'poster_path': movie['poster_path'],
                    'created_at': timestamp  # Add timestamp to the item
                }
            )
        except ClientError as e:
            print(f"Error saving movie {movie['title']}: {e.response['Error']['Message']}")

# Main handler function for AWS Lambda
def handler(event, context):
    tmdb_api_key = get_secret('AcmeLabsMovieDBTMDBKey')['apikey']
    genre_mapping = get_genres(tmdb_api_key)
    trending_movies = get_trending_movies(tmdb_api_key)

    for movie in trending_movies:
        movie['genres'] = [genre_mapping.get(genre_id, 'Unknown') for genre_id in movie['genre_ids']]

    save_to_dynamodb(trending_movies, genre_mapping)

    return {
        'statusCode': 200,
        'body': json.dumps(trending_movies, cls=DecimalEncoder)
    }

# Simulate AWS Lambda invocation locally
if __name__ == "__main__":
    mock_event = {}
    mock_context = {}
    result = handler(mock_event, mock_context)
    print(result)
