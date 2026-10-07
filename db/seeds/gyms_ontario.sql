-- Curated Ontario climbing gyms with bouldering (44 locations). Real public business data, safe for production.
-- Researched 2026-10-06 from each gym's own website (source_url). verified_on is null where the street address
-- came from a third-party source instead (see db/README.md); confirm those and set verified_on.
-- Idempotent: re-running updates rows by slug. Run as postgres (boulderme_api cannot write gyms).
begin;
insert into boulderme.gyms (slug, name, city, address, website_url, is_bouldering_only, source_url, verified_on, region, country)
select v.*, 'CA-ON', 'CA' from (values
  ('alt-rock', 'Alt. Rock', 'Barrie', '445 Dunlop St W Unit A, Barrie, ON L4N 1C3', 'https://www.altrock.co/', false, 'https://www.altrock.co/map/', null),
  ('the-boiler-room-climbing-gym-belleville', 'The Boiler Room Climbing Gym - Belleville', 'Belleville', '40 Hanna Ct, Belleville, ON', 'https://www.boilerroom.ca/belleville.html', true, 'https://www.boilerroom.ca/belleville.html', null),
  ('pinnacle-indoor-climbing', 'Pinnacle Indoor Climbing', 'Bowmanville', '330 Lake Rd, Bowmanville, ON L1C 4P8', 'https://pinnacleindoorclimbing.com/', false, 'https://pinnacleindoorclimbing.com/', '2026-10-06'::date),
  ('climb-muskoka', 'Climb Muskoka', 'Bracebridge', '24 Kirkhill Dr, Bracebridge, ON P1L 0A1', 'https://climbmuskoka.com/', false, 'https://climbmuskoka.com/', '2026-10-06'::date),
  ('toprock-climbing', 'Toprock Climbing', 'Brampton', '284 Orenda Rd Unit 8, Brampton, ON L6T 5S3', 'https://www.toprockclimbing.ca/', false, 'https://www.toprockclimbing.ca/', null),
  ('climbers-rock', 'Climber''s Rock', 'Burlington', '5155 Harvester Rd Unit 1, Burlington, ON L7L 6V2', 'https://climbersrock.com/', false, 'https://climbersrock.com/hours', '2026-10-06'::date),
  ('the-core-climbing-gym', 'The Core Climbing Gym', 'Cambridge', '500 Jamieson Pkwy Unit 1, Cambridge, ON N3C 0G5', 'https://www.thecoreclimbing.ca/', true, 'https://www.thecoreclimbing.ca/', '2026-10-06'::date),
  ('guelph-grotto', 'Guelph Grotto', 'Guelph', '199 Victoria Rd S, Guelph, ON N1E 6T9', 'https://www.guelphgrotto.com/', false, 'https://www.guelphgrotto.com/about', '2026-10-06'::date),
  ('gravity-climbing-gym-hamilton', 'Gravity Climbing Gym Hamilton', 'Hamilton', '70 Frid St Unit 6, Hamilton, ON L8P 4M4', 'https://www.gravityhamilton.com/', false, 'https://www.gravityhamilton.com/', '2026-10-06'::date),
  ('kingston-bouldering-co-operative', 'Kingston Bouldering Co-operative', 'Kingston', '12 Cataraqui St #4, Kingston, ON K7K 1Z7', 'https://kingstonboulderingcoop.com/', true, 'https://kingstonboulderingcoop.com/contact/', '2026-10-06'::date),
  ('the-boiler-room-climbing-gym-kingston', 'The Boiler Room Climbing Gym - Kingston', 'Kingston', '993 Princess St Unit 12, Kingston, ON', 'https://www.boilerroom.ca/kingston.html', false, 'https://www.boilerroom.ca/kingston.html', '2026-10-06'::date),
  ('grand-river-rocks-kitchener', 'Grand River Rocks Kitchener', 'Kitchener', '264 Victoria St N, Kitchener, ON N2H 5C8', 'https://grandriverrocks.com/kitchener/', false, 'https://grandriverrocks.com/kitchener/contact-us/', '2026-10-06'::date),
  ('j2-bouldering', 'J2 Bouldering', 'London', '1828 Blue Heron Dr Unit 1, London, ON N6H 0B7', 'https://www.j2bouldering.com/', true, 'https://www.j2bouldering.com/day-use-prices', '2026-10-06'::date),
  ('junction-climbing-centre', 'Junction Climbing Centre', 'London', '1030 Elias St Unit 2, London, ON N5W 3P6', 'https://www.junctionclimbing.com/', false, 'https://www.junctionclimbing.com/', '2026-10-06'::date),
  ('hub-climbing-markham', 'Hub Climbing Markham', 'Markham', '165 McIntosh Dr, Markham, ON L3R 0N6', 'https://hubclimbing.com/markham', false, 'https://hubclimbing.com/', '2026-10-06'::date),
  ('aspire-climbing-milton', 'Aspire Climbing Milton', 'Milton', '270 Bronte St N Unit 2, Milton, ON L9T 2N9', 'https://www.aspireclimbing.com/milton', true, 'https://www.aspireclimbing.com/milton', '2026-10-06'::date),
  ('boulderz-climbing-centre-the-cave-mississauga', 'Boulderz Climbing Centre - The Cave (Mississauga)', 'Mississauga', '1705 Argentia Rd Unit 5, Mississauga, ON L5N 3A9', 'https://boulderzclimbing.com/the-cave-mississauga-location/', true, 'https://boulderzclimbing.com/the-cave-mississauga-location/', '2026-10-06'::date),
  ('hub-climbing-mississauga', 'Hub Climbing Mississauga', 'Mississauga', '3636 Hawkestone Rd, Mississauga, ON L5C 2V2', 'https://hubclimbing.com/mississauga', false, 'https://hubclimbing.com/mississauga', '2026-10-06'::date),
  ('up-the-bloc', 'Up The Bloc', 'Mississauga', '1224 Dundas St E Unit 28, Mississauga, ON L4Y 4A2', 'https://upthebloc.com/', true, 'https://upthebloc.com/', '2026-10-06'::date),
  ('of-rock-and-chalk', 'Of Rock and Chalk', 'Newmarket', '482 Ontario St, Newmarket, ON L3Y 2K7', 'https://rockandchalk.com/', false, 'https://rockandchalk.com/', '2026-10-06'::date),
  ('altitude-gym-kanata', 'Altitude Gym Kanata', 'Ottawa', '501 Palladium Dr, Kanata, ON K2V 0E5', 'https://altitudegym.ca/en/kanata/', false, 'https://altitudegym.ca/en/kanata/', '2026-10-06'::date),
  ('altitude-gym-orleans', 'Altitude Gym Orléans', 'Ottawa', '265 Centrum Blvd, Orléans, ON K1E 3X7', 'https://altitudegym.ca/en/orleans/', true, 'https://altitudegym.ca/en/orleans/', '2026-10-06'::date),
  ('coyote-rock-gym', 'Coyote Rock Gym', 'Ottawa', '1737B St Laurent Blvd, Ottawa, ON K1G 3V4', 'https://coyoterockgym.ca/', false, 'https://coyoterockgym.ca/about-us/', '2026-10-06'::date),
  ('klimat-ottawa', 'Klimat Ottawa', 'Ottawa', '265 City Centre Ave, Ottawa, ON K1R 7R7', 'https://ottawa.klimat.ca/', true, 'https://ottawa.klimat.ca/', '2026-10-06'::date),
  ('the-climbers-crush', 'The Climbers Crush', 'Owen Sound', '1580 20th St E Unit 11, Owen Sound, ON N4K 3H1', 'https://climberscrush.com/', false, 'https://climberscrush.com/contact', '2026-10-06'::date),
  ('rock-and-rope-climbing-centre', 'Rock and Rope Climbing Centre', 'Peterborough', '280 Perry St Unit 16, Peterborough, ON K9J 2J4', 'https://www.rockandrope.com/', false, 'https://www.rockandrope.com/', '2026-10-06'::date),
  ('gravity-climbing-gym-niagara', 'Gravity Climbing Gym Niagara', 'St. Catharines', '399 Vansickle Rd Unit 3, St. Catharines, ON L2S 3T4', 'https://www.gravityniagara.com/', false, 'https://www.gravityniagara.com/', '2026-10-06'::date),
  ('arc-climbing-yoga', 'ARC Climbing & Yoga', 'Sudbury', '1981 Old Burwash Rd, Sudbury, ON P3E 4Z3', 'https://arcclimbing.ca/', false, 'https://arcclimbing.ca/', '2026-10-06'::date),
  ('rock-room', 'Rock Room', 'Thunder Bay', '319 Victoria Ave E, Thunder Bay, ON', 'https://www.rockroomclimbing.ca/', true, 'https://www.tbnewswatch.com/local-news/bouldering-gym-to-be-established-on-victoria-avenue-10726517', null),
  ('basecamp-climbing-bloor-west', 'Basecamp Climbing Bloor West', 'Toronto', '677 Bloor St West, Toronto, ON M6G 1L3', 'https://basecampclimbing.ca/bloor', false, 'https://basecampclimbing.ca/bloor', '2026-10-06'::date),
  ('basecamp-climbing-queen-west', 'Basecamp Climbing Queen West', 'Toronto', '186 Spadina Ave, Toronto, ON M5T 3A4', 'https://basecampclimbing.ca/queen', true, 'https://basecampclimbing.ca/queen', '2026-10-06'::date),
  ('boulder-parc', 'Boulder Parc', 'Toronto', '1415 Morningside Ave Unit 2, Scarborough, ON M1B 3J1', 'https://boulderparc.com/', true, 'https://boulderparc.com/', '2026-10-06'::date),
  ('boulderz-climbing-centre-the-big-gym-etobicoke', 'Boulderz Climbing Centre - The Big Gym (Etobicoke)', 'Toronto', '80 The East Mall Unit 9, Etobicoke, ON M8Z 5X1', 'https://boulderzclimbing.com/the-big-gym-etobicoke-location/', false, 'https://boulderzclimbing.com/the-big-gym-etobicoke-location/', '2026-10-06'::date),
  ('boulderz-climbing-centre-the-junction', 'Boulderz Climbing Centre - The Junction', 'Toronto', '1444 Dupont St Unit 16, Toronto, ON M6P 4H3', 'https://boulderzclimbing.com/the-junction-toronto-location/', false, 'https://boulderzclimbing.com/the-junction-toronto-location/', '2026-10-06'::date),
  ('ethos-climbing', 'Ethos Climbing', 'Toronto', '128 Queens Quay E, Toronto, ON', 'https://www.ethosclimbing.ca/', true, 'https://www.waterfrontbia.com/listing/ethos-climbing', null),
  ('hogtown-boulders', 'Hogtown Boulders', 'Toronto', '238 Lesmill Rd Unit A, Toronto, ON M3B 2T5', 'https://hogtownboulders.com/', true, 'https://hogtownboulders.com/', '2026-10-06'::date),
  ('joe-rockheads', 'Joe Rockhead''s', 'Toronto', '29 Fraser Ave, Toronto, ON M6K 1Y7', 'https://www.joerockheads.com/', false, 'https://rockoasis.com/', null),
  ('the-rock-oasis', 'The Rock Oasis', 'Toronto', '204-388 Carlaw Ave, Toronto, ON M4M 2T4', 'https://rockoasis.com/', false, 'https://rockoasis.com/', '2026-10-06'::date),
  ('toronto-climbing-academy', 'Toronto Climbing Academy', 'Toronto', '11 Curity Ave Unit 3, Toronto, ON M4B 1X4', 'https://climbingacademy.com/', false, 'https://climbingacademy.com/en/info/i24/Getting-Here.html', '2026-10-06'::date),
  ('true-north-climbing', 'True North Climbing', 'Toronto', '75 Carl Hall Rd Unit 14, Toronto, ON M3K 2B9', 'https://www.truenorthclimbing.com/', false, 'https://www.truenorthclimbing.com/location/', '2026-10-06'::date),
  ('rockhaus-climbing', 'RockHaus Climbing', 'Vaughan', '167 Chrislea Rd Unit 5, Vaughan, ON L4L 8N6', 'https://rockhausclimbing.com/', true, 'https://rockhausclimbing.com/contact-1', '2026-10-06'::date),
  ('grand-river-rocks-waterloo', 'Grand River Rocks Waterloo', 'Waterloo', '80 Lodge St Unit 1, Waterloo, ON N2J 2V6', 'https://grandriverrocks.com/waterloo/', true, 'https://grandriverrocks.com/waterloo/contact-us/', '2026-10-06'::date),
  ('aspire-climbing-whitby', 'Aspire Climbing Whitby', 'Whitby', '1400 Victoria St E Unit 4, Whitby, ON L1N 0M2', 'https://www.aspireclimbing.com/whitby', false, 'https://www.aspireclimbing.com/whitby', '2026-10-06'::date),
  ('windsor-rock-gym', 'Windsor Rock Gym', 'Windsor', '1215 Walker Rd, Windsor, ON N8Y 2N9', 'https://www.windsorrockgym.com/', true, 'https://www.windsorrockgym.com/', '2026-10-06'::date)
) as v(slug, name, city, address, website_url, is_bouldering_only, source_url, verified_on)
on conflict (slug) do update set
  name = excluded.name, city = excluded.city, address = excluded.address, website_url = excluded.website_url,
  is_bouldering_only = excluded.is_bouldering_only, source_url = excluded.source_url, verified_on = excluded.verified_on,
  region = excluded.region, country = excluded.country, is_active = true;
commit;
