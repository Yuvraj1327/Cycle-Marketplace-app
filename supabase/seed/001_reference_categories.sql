-- Reference categories from the quotation only. No fake business data. Safe to re-run.
insert into public.categories (kind, name, slug, sort_order) values
  ('new_cycle',  'New Cycles',  'new-cycles',  1),
  ('used_cycle', 'Used Cycles', 'used-cycles', 2),
  ('spare_part', 'Spare Parts', 'spare-parts', 3),
  ('accessory',  'Accessories', 'accessories', 4)
on conflict (slug) do nothing;

insert into public.service_categories (name, slug, sort_order) values
  ('General Servicing',  'general-servicing',  1),
  ('Puncture Repair',    'puncture-repair',    2),
  ('Brake Repair',       'brake-repair',       3),
  ('Gear Adjustment',    'gear-adjustment',    4),
  ('Parts Replacement',  'parts-replacement',  5)
on conflict (slug) do nothing;
